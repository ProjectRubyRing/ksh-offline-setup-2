# チャット内容: RHEL 9.6 ksh オフラインインストール

作成日: 2026-06-16

## 概要

NAT Gateway なしで `dnf` が外部リポジトリに接続できない AWS EC2 上の RHEL 9.6 に対して、事前取得した RPM 一式を使い `ksh` をオフラインインストールするための Bash スクリプトを作成した。

作成済みファイル:

- `ksh_offline_setup.sh`

スクリプトは `bash -n` で構文チェック済み。

## ユーザー要件

- RHEL 9.6 / AWS EC2 / Linux オフラインインストール前提。
- `ksh_offline_setup.sh` という 1 本の Bash スクリプトを作成。
- shebang は `#!/usr/bin/env bash`。
- `set -Eeuo pipefail`、エラー trap、ログ関数、usage 関数を含める。
- `prepare` / `install` / `verify` の 3 モードを実装。
- `prepare` はオンラインの同一 RHEL 9.6 環境で `dnf download --resolve ksh` を使い、RPM 一式、RPM 一覧、SHA256SUMS、OS/arch 情報を保存し、`ksh-offline-rhel9.6-<arch>.tar.gz` を作成する。
- `install` はオフライン環境で root 権限、RHEL 9 系、RPM 存在、SHA256 を確認し、外部リポジトリに依存せず `rpm -Uvh` で導入する。
- `--nodeps` や `--force` は使わない。
- `/etc/shells` に ksh パスがなければ追記する。
- `verify` は `rpm -q ksh`、`command -v ksh`、バージョン確認、簡単な ksh スクリプト実行確認を行う。
- 成功時に `ksh offline setup verification succeeded` と表示する。
- RHEL 9.6 以外の RHEL 9 系では警告して続行、RHEL 9 系以外では停止する。
- ksh が既に入っている場合は壊さず検証に進む。
- 依存関係不足などの失敗時は原因が分かるエラーメッセージを出す。

## 作成したスクリプトの要点

`ksh_offline_setup.sh` は以下を実装している。

- `prepare`
  - RHEL 9 系チェック。
  - `dnf download` が使えない場合は `dnf-plugins-core` を導入。
  - `dnf download --resolve --destdir <dir> ksh` を実行。
  - 利用可能な環境では `--alldeps` も追加して、依存 RPM の取りこぼしを減らす。
  - `OS-INFO.txt`、`RPMS.txt`、`SHA256SUMS` を生成。
  - `ksh-offline-rhel9.6-<arch>.tar.gz` を作成。

- `install`
  - root 権限チェック。
  - RHEL 9 系チェック。
  - 既に `ksh` が入っている場合は RPM 導入をスキップし、`/etc/shells` 確認後に `verify` へ進む。
  - RPM ファイル存在確認。
  - `SHA256SUMS` による改ざん・欠損チェック。
  - RPM アーキテクチャ確認。
  - `rpm -Uvh --test` で事前検査。
  - `rpm -Uvh` で導入。
  - `/etc/shells` に `ksh` のパスを追記。

- `verify`
  - `rpm -q ksh` を確認。
  - `command -v ksh` を確認。
  - `ksh --version` または `${.sh.version}` でバージョン確認。
  - 一時 ksh スクリプトを実行し、`42:ok` が返ることを確認。
  - 成功時に `ksh offline setup verification succeeded` を出力。

## 実行手順

### 1. オンライン側 RHEL 9.6 EC2 で RPM bundle を作成

```bash
chmod +x ./ksh_offline_setup.sh
sudo ./ksh_offline_setup.sh prepare --output-dir /tmp
```

生成物例:

```bash
/tmp/ksh-offline-rhel9.6-x86_64.tar.gz
```

### 2. オフライン側 EC2 へ転送

任意の方法で以下をオフライン側へ転送する。

```text
ksh-offline-rhel9.6-<arch>.tar.gz
ksh_offline_setup.sh
```

### 3. オフライン側 RHEL 9.6 EC2 で展開

```bash
tar -xzf ksh-offline-rhel9.6-x86_64.tar.gz
cd ksh-offline-rhel9.6-x86_64
```

### 4. install を実行

```bash
sudo /path/to/ksh_offline_setup.sh install --rpm-dir .
```

### 5. verify を単独実行する場合

```bash
/path/to/ksh_offline_setup.sh verify
```

成功時:

```text
ksh offline setup verification succeeded
```

## prepare/install/verify の実行例

オンライン側:

```bash
sudo ./ksh_offline_setup.sh prepare --output-dir /tmp
ls -l /tmp/ksh-offline-rhel9.6-$(uname -m).tar.gz
```

オフライン側:

```bash
tar -xzf ksh-offline-rhel9.6-x86_64.tar.gz
cd ksh-offline-rhel9.6-x86_64
sudo /path/to/ksh_offline_setup.sh install --rpm-dir .
```

検証:

```bash
/path/to/ksh_offline_setup.sh verify
```

## よくあるエラーと対処

### `dnf download is not available`

オンライン側で `dnf-plugins-core` が未導入。スクリプトは root 実行なら自動導入する。失敗する場合は Red Hat サブスクリプション、リポジトリ、ネットワーク到達性を確認する。

### `SHA256SUMS was not found`

`prepare` で作った tar.gz をそのまま展開していない、または `--rpm-dir` の指定が違う。展開後のトップディレクトリ、または `rpms` ディレクトリを指定する。

### `SHA256 verification failed`

RPM が欠けている、改変された、転送中に壊れた可能性がある。tar.gz を再転送する。

### `RPM dependency test failed`

オフライン側と prepare 側の RHEL 9.6、アーキテクチャ、有効リポジトリが一致していない可能性が高い。同じ RHEL 9.6 / 同じ arch の環境で `prepare` をやり直す。

### `RPM architecture mismatch`

`x86_64` 用 bundle を `aarch64` に持ち込んだ、またはその逆。オフライン EC2 と同じ `uname -m` の環境で `prepare` する。

## 補足

完全なスクリプト本体は同じディレクトリの `ksh_offline_setup.sh` に保存済み。
