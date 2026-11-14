# mitmproxy Docker 透過プロキシ環境（Tailscale exit node / WireGuard）

Docker と mitmproxy を使い、OSプロキシ設定を無視するアプリ（Flutter等）の通信をネットワーク（VPN）レベルで傍受・解析するためのプロキシ環境です。

スマホからの接続方法は2通りあり、同時に使えます。

| 方式 | スマホ側の操作 | 特徴 |
|---|---|---|
| **Tailscale exit node**（おすすめ） | Tailscale アプリで exit node `mitm-exit` を選ぶだけ | 普段の Tailscale と切り替え不要。LAN 外からも使える。エンドポイントの書き換え不要 |
| WireGuard | WireGuard アプリで QR を読み、Endpoint を書き換える | Tailscale アカウント不要 |

どちらも mitmproxy 側で **TCP / UDP（DNS・QUIC / HTTP/3）/ IPv6** を扱えます。

---

## 🛠️ 前提条件

*   Docker Desktop 4.42+ または OrbStack（Mac）、もしくは Docker（Linux）
*   スマートフォン側: 使う方式に応じて **Tailscale** または **WireGuard** アプリ

---

## 🚀 セットアップと起動

### 1. 設定ファイルの作成

```bash
cp .env.example .env
```

`.env` を開いて設定します。

```ini
# Web UI のログインパスワード
WEB_PASSWORD=your_secure_password

# Tailscale の auth key（Tailscale 方式を使う場合）
TS_AUTHKEY=tskey-auth-xxxxx
TS_HOSTNAME=mitm-exit
```

*   `TS_AUTHKEY` は [Tailscale 管理画面 → Settings → Keys](https://login.tailscale.com/admin/settings/keys) で発行します。
*   空のままでも起動でき、その場合は `docker compose logs tailscale` に表示される URL からログインします。
*   ログイン状態は `./tailscale_state/` に保存されるので、auth key は初回のみ使われます。

### 2. コンテナの起動

```bash
docker compose up -d
```

### 3. Web UI

ブラウザで `http://localhost:8085` を開き、`WEB_PASSWORD` でログインします。

---

## 📱 方式A: Tailscale exit node（おすすめ）

### 初回のみ

1.  [Tailscale 管理画面の Machines](https://login.tailscale.com/admin/machines) で `mitm-exit` の「…」→ **Edit route settings** → **Use as exit node** をオンにします。
2.  ACL（Access controls）を編集している場合は、スマホのユーザーが `autogroup:internet` を使えるようにしておきます（デフォルトの ACL なら不要）。

### 使うとき

iPhone の Tailscale アプリで **Exit Node → `mitm-exit`** を選ぶだけです。やめるときは Exit Node を None に戻します。
tailnet 内の他のマシンへの通信はこれまで通り使えます。

> 💡 同じ LAN 内では `41641/udp` 経由で直接つながります。`docker compose exec tailscale tailscale ping <スマホ名>` で `direct` になっているか確認できます（`relay` だと遅くなります）。

---

## 📱 方式B: WireGuard

Docker コンテナ内で動作している関係上、mitmproxy が表示する QR コード内の接続先（Endpoint）はコンテナ内の IP（`172.x.x.x:51820` 等）になっています。スキャン後にスマホ側でエンドポイントを書き換える必要があります。

1.  Web UI に表示される **WireGuard の QR コード** を WireGuard アプリの「+」→「QRコードから作成」で読み取り、保存します。
2.  作成したトンネルを「編集」し、`[Peer]` の **`Endpoint`** を **PC/Mac の LAN IP**（例: `192.168.1.150:51820`）に書き換えて保存し、VPN をオンにします。

> 💡 Mac の LAN IP は `ipconfig getifaddr en0` で確認できます。

---

## 🔑 CA証明書のインストールと信頼設定（HTTPS通信の解析）

exit node または VPN をオンにした状態で、スマホのブラウザから以下にアクセスします。

```
http://mitm.it
```

画面の指示に従ってプロファイルをダウンロードし、証明書を信頼してください（どちらの方式でも同じ証明書です）。

*   **iOS の場合**:
    1.  「設定」→「プロファイルがダウンロード済み」から mitmproxy をインストール。
    2.  「設定」→「一般」→「情報」→「証明書信頼設定」（一番下）を開く。
    3.  `mitmproxy` のスイッチを**オン**（信頼）にする。
*   **Android の場合**:
    1.  「設定」→「セキュリティ」→「暗号化と認証情報」→「資格情報のインストール」→「CA証明書」から、ダウンロードした証明書を選択してインストール。

---

## 🔍 通信の監視方法

`http://localhost:8085` のダッシュボードにトラフィックが流れ込みます。HTTP/1.1・HTTP/2・HTTP/3（QUIC）・DNS が表示されます。

> 💡 Tailscale 方式では、スマホが `100.100.100.100`（MagicDNS）に送る DNS 問い合わせは exit node 自身が処理するため、mitmproxy には表示されません。アプリが独自に DNS サーバーを指定している場合は表示されます。

---

## 🧩 仕組み（Tailscale 方式）

```
iPhone ─(Tailscale)─▶ tailscale0 ──ip rule: tailscale0 から来たものは table 100──▶ mitm0 ──▶ mitmproxy (--mode tun) ──▶ インターネット
```

| サービス | 役割 |
|---|---|
| `router` | ネットワーク名前空間の持ち主。mitmproxy 用の永続 TUN `mitm0` を作成し、tailscale0 から入ってきたパケットを mitm0 へ流すルーティングを維持する（[`scripts/router.sh`](scripts/router.sh)） |
| `tailscale` | exit node として tailnet に参加（カーネルモード） |
| `mitmproxy` | `mitm0` に TUN モードでアタッチして TCP/UDP を傍受。WireGuard モードも同時に提供。非 root で動作 |

*   `tailscale` と `mitmproxy` は `router` の名前空間に相乗りしているので、どちらを再起動しても数秒で復旧します。`router` を再起動した場合は `docker compose up -d --force-recreate` で全体を作り直してください。
*   コンテナから IPv6 で外に出られない環境では、IPv6 は mitmproxy に流さず到達不能として返し、端末側で IPv4 にフォールバックさせます。

---

## 🧪 動作確認テスト

Docker だけで、使い捨ての tailnet（headscale）とクライアントノードを立てて一通り検証できます（Tailscale アカウント不要）。

```bash
./test/run.sh                    # HTTP / HTTPS / DNS / HTTP/3 / IPv6 の傍受を検証
TEST_NO_IPV6=1 ./test/run.sh     # IPv6 が使えない環境を模擬（IPv4 へのフォールバックを検証）
KEEP=1 ./test/run.sh             # 終了後もスタックを残す（Web UI: http://127.0.0.1:18085）
```

---

## 🛑 終了方法

スマホ側で exit node / VPN をオフにし、以下のコマンドでコンテナを停止します。

```bash
docker compose down
```
