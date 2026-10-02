# Puma on Spinel

Build a Spinel application with Puma's Ragel HTTP parser linked through FFI:

```bash
bash spinel/build.sh spinel/server_smoke.rb tmp/spinel/server_smoke
```

The application can `require 'puma'`, create a `Puma::Configuration` with an
`app` and one TCP `port` or `bind`, then run it with `Puma::Single.new(config)`.
`Puma::Server.new(app)` with `add_tcp_listener(host, port)` also works directly.
The supplied smoke applications print their ports and exit after five seconds.

The current Spinel server is a single process with one TCP listener. It handles
Rack style responses, fixed `Content-Length` and chunked request bodies, GET,
POST, and HEAD. Responses with an explicit `Transfer-Encoding: chunked` are
framed as chunks. HTTP/1.1 connections stay open when the response has a known
length, uses chunked encoding, or has no body; unframed responses close the
connection. Request bodies are capped
at 16 MiB and larger bodies receive 413. Other transfer encodings receive 501.
TLS, Unix sockets, socket activation, runtime configuration files, and cluster
mode are outside this Spinel subset. Programmatic `Puma::Configuration` is
supported, including its maximum thread count.

The build script requires `spinel`, `cc`, and Bash. The parser
object is written under `tmp/spinel`; the binary goes to the output path you
provide.

Run `bash spinel/test.sh` to compile and test the parser, selector, direct
server, and single-mode runner.
