---
layout: single
title: "HTTP 요청 압축: 클라이언트가 보내는 Body도 gzip으로 줄일 수 있을까"
date: 2026-03-08 09:00:00 +0900
categories: [backend, network]
---

> [이전 글](/2026/03/07/http-gzip-compression)에서 서버가 응답을 압축하는 방법을 살펴봤다. 그런데 반대 방향은 어떨까? 클라이언트가 서버에 보내는 **요청 본문**도 압축할 수 있을까? OpenRTB에서는 초당 수십만 건의 bid request가 오가는데, gzip 하나로 네트워크 비용을 수천만 원 단위로 줄인다.

---

## 요청 압축이란

클라이언트가 request body를 gzip으로 압축한 뒤, `Content-Encoding: gzip` 헤더를 붙여서 보낸다. `Content-Type`은 원본 데이터의 타입을 그대로 유지한다.

```
POST /api/bid HTTP/1.1
Content-Type: application/json
Content-Encoding: gzip
Content-Length: 1234

<압축된 바이너리 body>
```

---

## 응답 압축과 뭐가 다른가

구조는 비슷해 보이지만 핵심적인 차이가 있다: **협상 방식**이 다르다.

### 응답 압축 — 사전 협상

```text
[클라이언트]                                    [서버]
    |--- Accept-Encoding: gzip, br ------------>|
    |                                            |  "gzip으로 보내줄게"
    |<--- Content-Encoding: gzip ---------------|
```

클라이언트가 먼저 "나 이런 압축 풀 수 있어"라고 알려주고, 서버가 그에 맞춰서 보낸다. 깔끔한 사전 협상이다.

### 요청 압축 — 사후 발견

```text
[클라이언트]                                    [서버]
    |--- Content-Encoding: gzip --------------->|
    |   (압축된 body)                            |
    |                                            |  "이거 풀 수 있나?"
    |<--- 200 OK 또는 415 Unsupported ----------|
```

요청 압축에는 `Accept-Encoding`에 대응하는 사전 협상 메커니즘이 없다. 클라이언트가 그냥 압축해서 보내고, 서버가 못 풀면 **`415 Unsupported Media Type`**을 돌려준다.

RFC 9110은 이 415 응답에 `Accept-Encoding` 헤더를 포함해서 "나는 이런 인코딩을 받을 수 있어"라고 알려줄 수 있도록 정의했다. 하지만 이건 사후 발견(backward discovery)이지, 사전 협상이 아니다.

정리하면, 응답 압축은 사전 협상이 있고 요청 압축은 없다. 이게 핵심 차이다. 실무에서 클라이언트는 어떻게 서버가 압축을 지원하는지 아는가? **API 문서를 읽는다.**

---

## 서버 지원 현황 — 생각보다 제한적

응답 압축은 거의 모든 서버가 지원하지만, 요청 압축은 다르다.

| 서버/프레임워크 | 요청 압축 해제 | 비고 |
|---|---|---|
| **Apache** | O | `mod_deflate` + `SetInputFilter DEFLATE` |
| **Nginx** | X | 네이티브 미지원. Lua 모듈로 우회 가능 |
| **Express.js** | O | `body-parser`가 기본으로 gzip inflate 지원 |
| **ASP.NET Core 7+** | O | `RequestDecompression` 미들웨어 |
| **Go `net/http`** | X | 자동 처리 없음. 직접 구현 필요 |
| **Django, Flask** | X | 서드파티 미들웨어 필요 |

Nginx가 지원하지 않는다는 게 의외다. 응답 압축의 `gzip on;`은 모든 Nginx 가이드에 나오지만, **들어오는 요청의 gzip을 풀어주는 기능은 없다.** `ngx_http_gunzip_module`은 응답 전용이다.

---

## 보안: Decompression Bomb

요청 압축을 열어두면 한 가지 보안 위험이 생긴다. **Decompression bomb**(zip bomb)이다.

공격자가 작은 압축 파일을 보내는데, 풀면 엄청나게 커진다. 반복 데이터를 극단적으로 압축한 것이다. 서버가 이걸 무방비로 풀면 메모리를 모두 소진하고 죽는다.

방어는 세 겹으로 한다:

1. **압축 상태 크기 제한** — wire size부터 체크. 너무 크면 아예 안 받는다
2. **스트리밍 해제 + 바이트 카운팅** — 한번에 전부 풀지 않고, 해제하면서 바이트를 세다가 임계값을 넘으면 중단
3. **압축 비율 제한** — Apache의 `DeflateInflateRatioLimit`은 압축 전/후 비율이 200:1을 넘으면 차단한다. 정상 JSON이 200배로 압축되는 건 사실상 불가능하다

참고로 이 위험은 요청 압축에만 한정되지 않는다. 악의적 서버가 응답에 bomb을 담아 보낼 수도 있다. 압축을 **해제하는 쪽**이라면 어느 방향이든 방어가 필요하다.

---

## OpenRTB — 요청 압축이 실제로 쓰이는 곳

요청 압축이 가장 활발하게 쓰이는 곳 중 하나가 **OpenRTB(Real-Time Bidding)**다.

SSP(Supply-Side Platform)가 DSP(Demand-Side Platform)에게 bid request를 보낼 때, JSON payload를 gzip으로 압축해서 전송한다. 왜 이게 의미 있는가:

- bid request payload가 consent string, 복수 EID 등으로 **점점 커지는 추세**다
- JSON 기준 gzip으로 보통 **60~80% 크기 감소** (3x~6x 압축률)
- 하루 수억 건 × 수 KB 절감 = **상당한 네트워크 비용 차이** (AWS는 egress에 GB 단위 과금)

OpenRTB 2.5/2.6 스펙은 gzip 압축을 명시적으로 다룬다:

- **요청 압축**: SSP가 `Content-Encoding: gzip`으로 bid request를 압축. **사전에 DSP와 합의 필요**
- **응답 압축**: SSP가 `Accept-Encoding: gzip`을 보내면 DSP가 알아서 압축 응답. 별도 합의 불필요 — 일반 HTTP 협상과 동일

여기서도 요청 압축과 응답 압축의 비대칭이 그대로 드러난다. 응답 압축은 HTTP 표준 협상을 따르니까 별도 합의 없이 되지만, 요청 압축은 사전 합의가 필요하다.

실제로 Smaato, InMobi 같은 SSP는 모든 파트너에게 요청 압축을 필수로 적용하고, OpenX, Index Exchange, BidSwitch 등은 선택 사항으로 두고 담당자에게 연락해서 활성화하는 구조다. 모든 플랫폼이 `Accept-Encoding: gzip`은 항상 보내므로, DSP가 응답을 압축하는 건 언제든 가능하다.

주의할 점: BidSwitch는 압축을 활성화한 후에도 **일부 요청이 비압축으로 올 수 있다**고 문서에 명시한다. DSP는 `Content-Encoding` 헤더 유무를 반드시 체크해서 분기해야 한다.

---

## Go 서버에서 gzip 요청 처리하기

앞서 서버 지원 현황에서 봤듯이, Go의 `net/http`는 요청 압축 해제를 자동으로 해주지 않는다. [이전 글](/2026/03/07/http-gzip-compression)에서 봤듯이 Transport가 `gzipReader`로 응답을 투명하게 풀어줬던 것과 달리, 서버 쪽은 수동이다.

미들웨어로 직접 만들어야 한다:

```go
const maxDecompressedSize = 10 << 20 // 10MB

func gzipRequestMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if !strings.EqualFold(r.Header.Get("Content-Encoding"), "gzip") {
            next.ServeHTTP(w, r)
            return
        }

        gz, err := gzip.NewReader(r.Body)
        if err != nil {
            http.Error(w, "invalid gzip body", http.StatusBadRequest)
            return
        }
        defer gz.Close()

        // LimitReader로 decompression bomb 방어
        r.Body = io.NopCloser(io.LimitReader(gz, maxDecompressedSize))
        r.Header.Del("Content-Encoding")
        r.ContentLength = -1

        next.ServeHTTP(w, r)
    })
}
```

핵심 포인트:

- `Content-Encoding: gzip`이면 `gzip.NewReader`로 감싸고, 아니면 그대로 통과시킨다
- **`io.LimitReader`로 해제 크기를 제한**해서 decompression bomb을 방어한다
- 헤더를 삭제하고 `ContentLength = -1`로 설정해서, 하위 핸들러는 압축을 신경 쓰지 않아도 된다
- 이전 글에서 본 Go 클라이언트의 자동 디코딩 패턴과 비슷한 구조다 — body를 래퍼로 감싸고, 헤더를 정리해서 투명하게 만든다

사용할 때는 핸들러를 감싸면 된다:

```go
mux := http.NewServeMux()
mux.HandleFunc("/bid", bidHandler)
http.ListenAndServe(":8080", gzipRequestMiddleware(mux))
```

테스트:

```bash
echo '{"id":"1","imp":[{"id":"1"}]}' | gzip > /tmp/bid.json.gz
curl -X POST http://localhost:8080/bid \
  -H "Content-Type: application/json" \
  -H "Content-Encoding: gzip" \
  --data-binary @/tmp/bid.json.gz
```

`--data-binary`를 써야 한다. `-d`나 `--data`는 바이너리 데이터를 망가뜨린다.

---

## 정리

| 구분 | 응답 압축 | 요청 압축 |
|---|---|---|
| 헤더 | `Accept-Encoding` → `Content-Encoding` | `Content-Encoding`만 |
| 협상 | 사전 (`Accept-Encoding`) | 사후 (415 + API 문서) |
| 서버 지원 | 거의 모든 서버 | Apache, Express 등 일부만 |
| 보안 | decompression bomb 가능 | decompression bomb 가능 |
| 주요 사용처 | 웹 전반 | 서비스 간 통신 (OpenRTB, gRPC, OTLP) |

요청 압축은 응답 압축만큼 보편적이지 않지만, **대용량 JSON을 대량으로 주고받는 서비스 간 통신**에서는 의미 있는 최적화다. 도입을 고려한다면: payload가 일관되게 1KB 이상이고, 초당 수백 건 이상의 트래픽이 있고, 서버가 이를 지원하는지 확인하자. 그리고 decompression bomb 방어를 빠뜨리지 말자.

---

## 참고 자료

### HTTP 스펙

- [RFC 9110 — HTTP Semantics, §8.4 Content-Encoding](https://www.rfc-editor.org/rfc/rfc9110#section-8.4)
- [RFC 9110 — §12.5.3 Accept-Encoding](https://www.rfc-editor.org/rfc/rfc9110#section-12.5.3)
- [RFC 9110 — §15.5.16 415 Unsupported Media Type](https://www.rfc-editor.org/rfc/rfc9110#section-15.5.16)
- [MDN — Content-Encoding](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Encoding)
- [MDN — HTTP Compression](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Compression)

### 서버/프레임워크

- [Apache mod_deflate — Input Decompression](https://httpd.apache.org/docs/current/mod/mod_deflate.html#input-decompression)
- [Nginx ngx_http_gunzip_module (응답 전용)](https://nginx.org/en/docs/http/ngx_http_gunzip_module.html)
- [Express body-parser — inflate 옵션](https://www.npmjs.com/package/body-parser)
- [ASP.NET Core — Request Decompression](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/middleware/request-decompression)
- [Go net/http](https://pkg.go.dev/net/http) · [compress/gzip](https://pkg.go.dev/compress/gzip)

### OpenRTB

- [OpenRTB 2.5 Specification (IAB, PDF)](https://www.iab.com/wp-content/uploads/2016/03/OpenRTB-API-Specification-Version-2-5-FINAL.pdf)
- [OpenRTB 2.6 Specification (GitHub)](https://github.com/InteractiveAdvertisingBureau/openrtb2.x/blob/main/2.6.md)
- [Smaato — GZIP Compression](https://developers.smaato.com/demand-partners/gzip-compression/)
- [Index Exchange — Compress Traffic Using GZIP](https://kb.indexexchange.com/dsps/managing_your_traffic/compress_traffic_using_GZIP.htm)
- [BidSwitch — Data Format (Compression)](https://protocol.bidswitch.com/standards/data-format.html)

### 보안

- [Zip bomb — Wikipedia](https://en.wikipedia.org/wiki/Zip_bomb)
- [OpenTelemetry Collector Decompression Bomb CVE (GHSA-c74f-6mfw-mm4v)](https://github.com/advisories/GHSA-c74f-6mfw-mm4v)
- [A Better Zip Bomb — David Fifield (USENIX WOOT 2019)](https://www.bamsoftware.com/hacks/zipbomb/)
