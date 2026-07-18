# Options reference

Raw libcurl options pass through `setopt` — as top-level kwargs on any verb,
via the `setopt:` escape hatch, or on a `URL::Request` / session directly.
Symbols map 1:1 to the `CURLOPT_` / `CURLMOPT_` constants below; values are
validated by libcurl itself.

## Tuning the shared session

`URL.shared` is the session every blocking verb reuses. Tune its pool once at
startup:

```ruby
URL.shared.setopt(:pipelining,             2)    # CURLPIPE_MULTIPLEX (HTTP/2)
URL.shared.setopt(:max_concurrent_streams, 100)
URL.shared.setopt(:max_total_connections,  256)
```

## `URL#setopt` (1:1 with `curl_multi_setopt`)

| Symbol | `CURLMOPT_` | Notes |
| --- | --- | --- |
| `:pipelining` | PIPELINING | bitmask; `2` (CURLPIPE_MULTIPLEX) for HTTP/2 |
| `:maxconnects` | MAXCONNECTS | connection-cache size |
| `:max_host_connections` | MAX_HOST_CONNECTIONS | per-origin cap (HTTP/1.1) |
| `:max_total_connections` | MAX_TOTAL_CONNECTIONS | global cap |
| `:max_concurrent_streams` | MAX_CONCURRENT_STREAMS | HTTP/2 client-side |

## `URL::Request#setopt` (1:1 with `curl_easy_setopt`)

| Symbol | `CURLOPT_` |
| --- | --- |
| `:url` | URL |
| `:custom_request` | CUSTOMREQUEST |
| `:user_agent` | USERAGENT |
| `:cainfo` | CAINFO |
| `:accept_encoding` | ACCEPT_ENCODING |
| `:userpwd` | USERPWD |
| `:netrc` | NETRC (`0`/`1`/`2`) |
| `:netrc_file` | NETRC_FILE |
| `:proxy` | PROXY |
| `:cookiefile` | COOKIEFILE |
| `:cookiejar` | COOKIEJAR |
| `:follow_location` | FOLLOWLOCATION |
| `:max_redirs` | MAXREDIRS |
| `:verbose` | VERBOSE |
| `:timeout` | TIMEOUT_MS (chrono duration → ms) |
| `:connect_timeout` | CONNECTTIMEOUT_MS (chrono duration → ms) |
| `:ssl_verify_peer` | SSL_VERIFYPEER |
| `:ssl_verify_host` | SSL_VERIFYHOST |
| `:nobody` | NOBODY |
| `:connect_only` | CONNECT_ONLY |
| `:upload` | UPLOAD |
| `:mail_from` | MAIL_FROM |
| `:mail_rcpt` | MAIL_RCPT (Array) |
| `:post_fields` | COPYPOSTFIELDS (size from POSTFIELDSIZE_LARGE) |
| `:mimepost` | MIMEPOST (a `URL::Libcurl::Mime`; built for you by `multipart:`) |
| `:range` | RANGE |
| `:infilesize` | INFILESIZE_LARGE |
| `:dirlistonly` | DIRLISTONLY |
| `:ftp_create_dirs` | FTP_CREATE_MISSING_DIRS |
| `:use_ssl` | USE_SSL (`0`–`3`) |
| `:ssh_knownhosts` / `:ssh_private_keyfile` / `:ssh_public_keyfile` | SSH_KNOWNHOSTS / SSH_PRIVATE_KEYFILE / SSH_PUBLIC_KEYFILE |
| `:rtsp_request` / `:rtsp_stream_uri` / `:rtsp_transport` | RTSP_REQUEST / RTSP_STREAM_URI / RTSP_TRANSPORT |

Client TLS:

| Symbol | `CURLOPT_` |
| --- | --- |
| `:sslcert` / `:sslkey` / `:keypasswd` | SSLCERT / SSLKEY / KEYPASSWD |
| `:capath` | CAPATH |
| `:pinnedpublickey` | PINNEDPUBLICKEY |
| `:ssl_cipher_list` | SSL_CIPHER_LIST |
| `:sslversion` | SSLVERSION (curl integer enum) |

HTTP / proxy / network:

| Symbol | `CURLOPT_` |
| --- | --- |
| `:http_version` | HTTP_VERSION (curl integer enum: `2`=1.1, `3`=2, `30`=3) |
| `:cookie` | COOKIE (inline `"a=1; b=2"`) |
| `:unrestricted_auth` | UNRESTRICTED_AUTH |
| `:postredir` | POSTREDIR |
| `:proxyuserpwd` | PROXYUSERPWD |
| `:proxytype` | PROXYTYPE (curl integer enum) |
| `:httpproxytunnel` | HTTPPROXYTUNNEL |
| `:noproxy` | NOPROXY |
| `:interface` | INTERFACE |
| `:dns_servers` | DNS_SERVERS |
| `:doh_url` | DOH_URL |
| `:max_send_speed` / `:max_recv_speed` | MAX_SEND_SPEED_LARGE / MAX_RECV_SPEED_LARGE (bytes/s) |
| `:tcp_keepalive` | TCP_KEEPALIVE |
| `:tcp_keepidle` / `:tcp_keepintvl` | TCP_KEEPIDLE / TCP_KEEPINTVL (chrono duration → s) |
| `:unix_socket_path` | UNIX_SOCKET_PATH |

## Auth

`auth:`/`bearer:`/`userpwd:` (Basic, Bearer) and `netrc:` are the
supported auth paths. NTLM and Digest are intentionally **not** exposed —
curl is removing NTLM (Sep 2026) and the local-crypto Digest fallback (Oct
2026); Basic + Bearer + TLS client certs are the durable options.

## Headers

Pass `headers: { ... }` to a one-shot, or `Request#headers=`.
