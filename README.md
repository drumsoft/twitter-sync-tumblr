# 概要

twitter-sync-tumblr は、 Twitter にアップされた写真を Tumblr にアップロードするスクリプトです。

## 特徴

 * Twitter の写真とコメントを、 Tumblr に写真とキャプションとしてアップロードします。
 * Twitter のアップロード日付を Tumblr の投稿日付として保存します。
 * 最初は全ての写真を Tumblr にアップロードします。次回以降はまだアップロードしていない写真だけをアップロードするので、繰り返し起動する事で常に Twitter の内容が Tumblr に同期している状態にする事ができます。
 * Tumblr への投稿に任意の決まったタグをつけられるので、 Twitter からの転載分だけ後から分けて確認する事ができます。


# 起動オプションと引数

    perl twitter-sync-tumblr.pl
    perl twitter-sync-tumblr.pl --config
    perl twitter-sync-tumblr.pl --quiet
    perl twitter-sync-tumblr.pl STATUS_ID [ STATUS_ID]..

 * 何もオプションを起動しない場合は、 Twitter からまだアップロードしていない写真を全て Tumblr にアップロードします。
 * -c, --config : エディタを起動して設定を変更します。
 * -q, --quiet : 自動実行時に使う、エラー以外のメッセージを出力しないモードです。
 * STATUS_ID : 指定した ID の Twitter ポストに含まれる画像をアップロードします。


# 使い方|チュートリアル

## 1. 準備

### 1-1. Twitter 連携アプリケーションを登録して API の Access token を取得する

https://dev.twitter.com/apps

で Create a new application をクリックして新しい application をつくります。

作成した application のページで以下を取得します。

 * Consumer key
 * Consumer secret
 * Access token
 * Access token secret

この辺はググると詳しい説明が出てきます。

### 1-2. Tumblr の Consumer Key を取得する

http://www.tumblr.com/oauth/apps

で アプリケーションを登録 というボタンから以下を登録します

 * Application name: twitter-sync-tumblr
 * Application website: 自分のサイトのURL または http://localhost/
 * Application description: Sync Twitter and Tumblr
 * Administrative contact email: 自分のメアド
 * Default callback URL: http://localhost/
 * Icon: 登録しなくてOK

登録すると OAuth Consumer Key: が表示されます。
Show Secret Key をクリックすると Secret Key も表示されます。
この2つをメモります。

これは以降 Tumblr の consumer_key と consumer_secret と呼ばれます。


### 1-3. EDITOR 環境変数を登録する

EDITOR 環境変数が未設定の場合、これを設定します。

    env | grep EDITOR

というコマンドで確認できます。

設定は以下の様なコマンドで、好きなエディタを設定します。

    export EDITOR=emacs
    export EDITOR=vi

（環境変数を恒久的に設定したい場合は .profile 等に上記コマンドを書く必要があります。詳しくはWebで）


### 1-4. 設定を書き込む

コマンドラインで `perl twitter-sync-tumblr.pl` と入力してこのスクリプトを起動します。

初回起動時の場合は、自動的に EDITOR に設定したエディタで設定ファイルが開かれます。まず Twitter の設定ファイルが開かれるので、

 * screen_name に 自分の Twitter アカウント名
 * あと4つは先ほど取得したもの

をファイルに書き（シングルクォートは消さずにその中に書く）、
保存してエディタを終了します。

次に Tumblr の設定ファイルが開かれるので、

 * 自分の Tumblr ホスト名（MYNAME.tumblr.com みたいなやつ）
 * アップした写真につけたいタグ
 * slugのprefix(※)
 * Tumblr の consumer_key
 * Tumblr の consumer_secret

をファイルに書き、保存してエディタを終了します。

※各ポストのURL末尾につけられる記号を slug と呼びます。 twitter-sync-tumblr は、任意のprefixとTwitterの HASH (TwitterのURL末尾の、写真を一意に識別する為の記号) をくっつけたものを slug として指定します。ここで、その prefix を指定して下さい。分からなければ 'Twitter_' がオススメです。

1度設定すると、次回以降の起動では設定ファイルは開かれません。後から設定をやり直したい場合、 `perl twitter-sync-tumblr.pl --config` と --config オプションを指定して起動して下さい。設定は `~/.pit/default.yaml` に保存されています。


### 1-5. Tumblr の oAuth 認証を行う

初回起動時と Tumblr の oAuth 認証失敗時には、 oAuth 認証プロセスが始まります。
コマンドラインに表示される URL をコピーして、ブラウザで開き、認証ボタンを押して下さい。
こんどはリダイレクトされた先のURLをコピーし、コマンドラインに入力して下さい。

以上で認証が完了します。認証の結果は、 1-4 の Tumblr 設定ファイルに保存されています。他のアカウントで使いたい場合等、認証をやり直したい場合は、 `perl twitter-sync-tumblr.pl --config` で起動して Tumblr 設定ファイルから `"access_token" : ...` という行を削除して下さい。

認証プロセスの終了後は、スクリプトは何もせずに終了する様になっています。
これで準備は終了です。


## 2 使い方

### 2-1. 既存の写真をまとめてアップロード/新規写真をアップロードする

コマンドラインで `perl twitter-sync-tumblr.pl` と入力してこのスクリプトを起動します。
Twitter のポストを新しい物順に読み込み、読み込み可能な最後のポスト（現在は3200ポストまで）まで読み込むか、既にアップロードした写真に到達したら読み込みを終了します。

読み込みが終了したら、写真を古い順に Tumblr にアップロードしはじめます。

最初は何もアップロードしていないので、 Twitter の全ての写真が Tumblr にアップロードされます。
おそらく、1日のアップロード枚数制限(80枚くらい)にひっかかって、途中でエラー終了すると思います。翌日以降にまたチャレンジしましょう。

2回目以降は、前回までにアップロード完了した写真以降がアップロードされます。

### 2-2. 写真を指定してアップロードする

コマンドラインで引数に Twitter の Status ID を指定すると、そのポストに含まれる写真だけをアップロードします。 ID は複数同時に指定できます。この方法では、最新から 3200ポスト目 以降の古いポストについてもアップロードができます。


## 3. アップロード済みの写真を管理する

どこまで写真をアップロードしたかの記録は、 `.lastid.twitter-sync-tumblr.pl` というファイルに保存されています。このファイルには、アップロードした最新の写真に対応する Status ID が記録されています。この記録を書き換えれば、遡ってアップロードし直しが可能です。

全ての写真をアップロードしなおすには: `.lastid.twitter-sync-tumblr.pl` を削除して下さい。


## 4. 自動化する

`perl twitter-sync-tumblr.pl` の実行を自動化すれば、今後 Twitter にアップした写真を自動的に Tumblr に反映させる事ができます。

自動化の際は --quiet オプションを付けて、エラー時のメッセージだけが出力される様にするとよいと思います。

Mac の場合は launchd, Linux は crontab, Windows は タスク, で検索して設定してみて下さい。

