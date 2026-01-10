# Docker Multi-Service Infrastructure

このプロジェクトは、Traefikリバースプロキシを中心としたマルチサービスインフラストラクチャです。
IPv6対応、固定IPアドレス割り当て、そして2つの独立したTraefikインスタンス（public/private）による
きめ細かなアクセス制御を提供します。

## 目次

- [アーキテクチャ概要](#アーキテクチャ概要)
- [前提条件](#前提条件)
- [初期セットアップ](#初期セットアップ)
  - [1. Docker Daemonの設定](#1-docker-daemonの設定)
  - [2. External Networkの作成](#2-external-networkの作成)
  - [3. 環境変数の設定](#3-環境変数の設定)
- [デプロイ](#デプロイ)
- [サービス一覧](#サービス一覧)
- [トラブルシューティング](#トラブルシューティング)

## アーキテクチャ概要

### Traefikの2つのインスタンス

このインフラストラクチャは、異なるアクセス制御要件に対応するため、
2つの独立したTraefikリバースプロキシを運用します。

#### Public Traefik

- **用途**: cloudflare経由の公開(cloudflare側でアクセス制限をかける 公開しているので，private traefikよりも条件を厳しく設定する)
- **アクセス制御**: Cloudflareからのアクセスのみを許可
  - `CF_IPS` 環境変数で指定されたCloudflare IPレンジからの接続のみ受け入れ
  - Cloudflare経由でのみサービスにアクセス可能（DDoS保護、キャッシング等の恩恵）
- **ポート**: 80（HTTP）、443（HTTPS）
- **ネットワーク**: `public-traefik`
- **証明書**: Let's Encrypt (DNS-01チャレンジ / Cloudflare)
- **識別ラベル**: `traefik.public=true`

#### Private Traefik

- **用途**: VPN経由の内部アクセスを処理
- **アクセス制御**: VPN経由のアクセスのみを許可
  - `VPN_SERVER_IP` 環境変数で指定されたWireGuardサーバーからの接続のみ受け入れ
  - VPNクライアントのみが内部サービスにアクセス可能
- **固定IP**: IPv4とIPv6の両方で固定アドレスを使用
  - WireGuardの `ALLOWEDIPS` 設定で到達可能性を保証
- **ネットワーク**: `private-traefik`
- **証明書**: Let's Encrypt (DNS-01チャレンジ / Cloudflare)
- **識別ラベル**: `traefik.private=true`

### サービスのルーティング

各サービスは、必要に応じて両方のTraefikインスタンスにルーティングを設定できます：

```yaml
labels:
  # Public Traefik経由のルーティング（Cloudflareから）
  - "traefik.public=true"
  - "traefik.http.routers.myapp-public.rule=Host(`example.com`)"
  - "traefik.http.routers.myapp-public.entrypoints=websecure"
  - "traefik.http.routers.myapp-public.tls.certresolver=le"
  - "traefik.http.routers.myapp-public.middlewares=access-allow-chain@docker"

  # Private Traefik経由のルーティング（VPNから）
  - "traefik.private=true"
  - "traefik.http.routers.myapp-private.rule=Host(`example.com`)"
  - "traefik.http.routers.myapp-private.entrypoints=websecure"
  - "traefik.http.routers.myapp-private.tls.certresolver=le"
  - "traefik.http.routers.myapp-private.middlewares=access-allow-chain@docker"
```

## 前提条件

- Docker Engine 25.0以降
- Docker Compose v2.20以降
- Cloudflareアカウント（DNS管理とAPI Token）
- ドメイン名（CloudflareでDNS管理）

## 初期セットアップ

### 1. Docker Daemonの設定

IPv6とカスタムネットワーク設定を有効にするため、Docker Daemonの設定ファイルを作成・編集します。

#### `/etc/docker/daemon.json`

```json
{
  "ipv6": true,
  "fixed-cidr-v6": "fd00::/80",
  "experimental": true,
  "ip6tables": true,
  "default-address-pools": [
    {
      "base": "172.17.0.0/16",
      "size": 24
    },
    {
      "base": "172.18.0.0/16",
      "size": 24
    },
    {
      "base": "192.168.0.0/16",
      "size": 24
    }
  ]
}
```

**設定項目の説明:**

- `ipv6`: IPv6サポートを有効化
- `fixed-cidr-v6`: デフォルトのIPv6サブネット（ULA範囲）
- `experimental`: 実験的機能を有効化（一部の高度なネットワーク機能に必要）
- `ip6tables`: IPv6のiptablesサポート
- `default-address-pools`: カスタムIPv4アドレスプールの定義
  - 複数のネットワークを作成する際のIPアドレス範囲
  - `size`は各ネットワークのサブネットサイズ（/24 = 254ホスト）

**設定を適用:**

```bash
sudo systemctl restart docker
```

**注意:** Docker Daemonの再起動により、実行中のコンテナは停止します。

### 2. External Networkの作成

Traefikリバースプロキシと各サービス間の通信用に、2つのexternal networkを作成します。
これらのネットワークは固定IPアドレス割り当てとIPv6をサポートします。

#### Public Traefik Network

```bash
docker network create \
  --driver=bridge \
  --ipv6 \
  --subnet=172.20.0.0/16 \
  --gateway=172.20.0.1 \
  --subnet=fd00:172:20::/48 \
  --gateway=fd00:172:20::1 \
  public-traefik
```

#### Private Traefik Network

```bash
docker network create \
  --driver=bridge \
  --ipv6 \
  --subnet=172.21.0.0/16 \
  --gateway=172.21.0.1 \
  --subnet=fd00:172:21::/48 \
  --gateway=fd00:172:21::1 \
  private-traefik
```

**オプションの説明:**

- `--driver=bridge`: Dockerブリッジネットワークを使用
- `--ipv6`: IPv6を有効化
- `--subnet`: IPv4サブネット範囲（/16 = 65534ホスト）
- `--gateway`: IPv4ゲートウェイアドレス
- `--subnet` (2回目): IPv6サブネット範囲（ULA範囲）
- `--gateway` (2回目): IPv6ゲートウェイアドレス

**ネットワークの確認:**

```bash
docker network ls
docker network inspect public-traefik
docker network inspect private-traefik
```

### 3. 環境変数の設定

各サービスのディレクトリに `.env` ファイルを作成します。

#### `traefik-proxy/.env`

```env
# Let's Encrypt設定
LE_EMAIL=your-email@example.com

# Cloudflare API Token（DNS-01チャレンジ用）
CF_DNS_API_TOKEN=your_cloudflare_api_token

# Cloudflare IPレンジ（カンマ区切り）
# 最新のリストは https://www.cloudflare.com/ips/ から取得
CF_IPS=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,2405:8100::/32,2a06:98c0::/29,2c0f:f248::/32

# Private Traefik固定IP
PRIVATE_TRAEFIK_IPV4=172.21.0.10
PRIVATE_TRAEFIK_IPV6=fd00:172:21::10

# VPNサーバーIP（WireGuardサーバーがprivate-traefik内で使用するIP）
VPN_SERVER_IP=172.21.0.100
```

#### `wireguard/.env`

```env
# WireGuard設定
VPN_HOST=vpn.example.com
VPN_PEERS=peer1,peer2,peer3

# DNS設定（Pi-holeのIP）
DNS_IP=172.22.0.10
DNS_SUBNET=172.22.0.0/24
DNS_GATEWAY=172.22.0.1

# VPNクライアントの内部サブネット
INTERNAL_SUBNET=10.13.13.0/24

# Private Traefikへの到達性
PRIVATE_TRAEFIK_IP=172.21.0.10
PRIVATE_TRAEFIK_NETWORK_VPN_SERVER_IP=172.21.0.100

# Pi-hole Web UI
APP_HOST=pihole.example.com
```

**WireGuard ALLOWEDIPSについて:**

WireGuardの `ALLOWEDIPS` は、VPNクライアントがアクセスできるIPアドレス範囲を制御します。
Private Traefikの固定IPとDNSサーバー（Pi-hole）のIPを指定することで、
VPN経由でのみ内部サービスにアクセスできるようにします。

```yaml
ALLOWEDIPS: ${DNS_IP}/32,${PRIVATE_TRAEFIK_IP}/32
```

#### 各サービスの `.env`

各サービス（gitea、vaultwarden、hashicorp-vault）には、以下のような設定が必要です：

```env
# 共通設定
APP_HOST=service.example.com

# データベース認証情報
DB_USER=dbuser
DB_PASSWORD=secure_password

# サービス固有の設定
# ...
```

**セキュリティ上の注意:**

`.env` ファイルには機密情報が含まれるため、適切に保護してください：

```bash
chmod 600 */.env
```

また、`.gitignore` に `.env` を追加してバージョン管理から除外することを推奨します。

## デプロイ

### Makefileを使った一括デプロイ

プロジェクトルートの `Makefile` を使用して、すべてのサービスを適切な順序でデプロイできます。

```bash
# すべてのサービスを起動
make up

# すべてのサービスを停止
make down
```

**起動の優先順位:**

Makefileは、固定IPを使用するコンテナを優先的に起動します：

1. **優先起動** (固定IP使用):
   - `traefik-proxy/` (public-traefik, private-traefik)
   - `wireguard/` (WireGuard VPNサーバー, Pi-hole)

2. **通常起動**:
   - その他のすべてのサービス

この順序により、ネットワークの固定IPアドレスが確実に割り当てられ、
依存関係のあるサービスが適切に接続できます。

### 個別サービスのデプロイ

特定のサービスのみをデプロイする場合：

```bash
cd traefik-proxy
docker compose up -d

cd ../gitea
docker compose up -d
```

### デプロイの確認

```bash
# すべてのコンテナの状態を確認
docker ps

# 特定のサービスのログを確認
docker compose -f gitea/docker-compose.yml logs -f

# Traefikのルーティングを確認
docker logs public-traefik
docker logs private-traefik
```

## サービス一覧

### 1. Traefik Proxy (`traefik-proxy/`)

**Public Traefik:**

- Cloudflare経由の公開アクセスを管理
- HTTP/HTTPS (ポート 80/443)
- Let's Encrypt自動証明書取得

**Private Traefik:**

- VPN経由の内部アクセスを管理
- 固定IPv4/IPv6アドレス
- Let's Encrypt自動証明書取得

### 2. WireGuard VPN (`wireguard/`)

- VPNサーバー（ポート 51820/UDP）
- Pi-hole統合（広告ブロック＋プライベートDNS）
- Private Traefikへのルーティング

**管理:**

```bash
# クライアント設定QRコード表示
docker exec -it wireguard /app/show-peer peer1

# ピア追加
# .envのVPN_PEERSを編集して再起動
docker compose -f wireguard/docker-compose.yml restart
```

### 3. Gitea (`gitea/`)

- Git hosting platform
- MySQL 8バックエンド
- SSH (ポート 2222)
- Public/Private両方でアクセス可能

### 4. Vaultwarden (`vaultwarden/`)

- Bitwarden互換パスワードマネージャー
- PostgreSQL 18バックエンド
- Public/Private両方でアクセス可能

### 5. HashiCorp Vault (`hashicorp-vault/`)

- シークレット管理
- ファイルストレージバックエンド
- Public/Private両方でアクセス可能


## メンテナンス

### アップデート

安全に使いたければイメージのバージョンを固定することをおすすめします．

```bash
# イメージの更新
docker compose -f traefik-proxy/docker-compose.yml pull
docker compose -f gitea/docker-compose.yml pull
docker compose -f vaultwarden/docker-compose.yml pull
docker compose -f hashicorp-vault/docker-compose.yml pull
docker compose -f wireguard/docker-compose.yml pull

# サービスの再起動（優先順位を考慮）
make down
make up
```

### ログローテーション

Docker Daemonのログローテーション設定（`/etc/docker/daemon.json`に追加）:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

## 参考リンク

- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Docker Networking](https://docs.docker.com/network/)
- [WireGuard](https://www.wireguard.com/)
- [Cloudflare IP Ranges](https://www.cloudflare.com/ips/)
- [Let's Encrypt](https://letsencrypt.org/)
