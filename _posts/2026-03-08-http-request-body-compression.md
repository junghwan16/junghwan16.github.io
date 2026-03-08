---
layout: single
title: "HTTP 요청 압축: 클라이언트가 보내는 Body도 gzip으로 줄일 수 있을까"
date: 2026-03-08 09:00:00 +0900
categories: [backend, network]
---

> [이전 글](/2026/03/07/http-gzip-compression)에서 서버가 응답을 압축하는 방법을 살펴봤다. 그런데 반대 방향은 어떨까? 클라이언트가 서버에 보내는 **요청 본문**도 압축할 수 있을까? OpenRTB처럼 초당 수십만 건의 JSON을 주고받는 환경에서는 이게 실제로 쓰인다.

---

## 요청 압축이란

이전 글에서 본 **응답 압축**은 서버 → 클라이언트 방향이었다. **요청 압축**은 그 반대다. 클라이언트가 request body를 gzip으로 압축해서 보내고, 서버가 이를 풀어서 처리한다.

사용하는 헤더는 동일하다. `Content-Encoding: gzip`을 요청에 붙이면 된다.

```
POST /api/bid HTTP/1.1
Content-Type: application/json
Content-Encoding: gzip
Content-Length: 1234

<압축된 바이너리 body>
```

`Content-Type`은 원본 데이터의 타입을 그대로 유지한다. `Content-Length`는 **압축된 후의 크기**다.

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

| 구분 | 응답 압축 | 요청 압축 |
|---|---|---|
| 방향 | 서버 → 클라이언트 | 클라이언트 → 서버 |
| 협상 | `Accept-Encoding` → `Content-Encoding` | 없음. 보내고 → 안 되면 415 |
| 보편성 | 거의 모든 서버·클라이언트 지원 | 서버 지원이 제한적 |

실무에서 클라이언트는 어떻게 서버가 압축을 지원하는지 아는가? **API 문서를 읽는다.** 표준 프로토콜 내에서 알아낼 수 있는 깔끔한 방법은 없다.

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

1. **압축 상태 크기 제한** — `Content-Length`(wire size)부터 체크. 너무 크면 아예 안 받는다
2. **스트리밍 해제 + 바이트 카운팅** — 한번에 전부 풀지 않고, 해제하면서 바이트를 세다가 임계값을 넘으면 중단
3. **압축 비율 제한** — Apache의 `DeflateInflateRatioLimit`은 압축 전/후 비율이 200:1을 넘으면 차단한다. 정상 JSON이 200배로 압축되는 건 사실상 불가능하다

참고로 이 위험은 요청 압축에만 한정되지 않는다. 악의적 서버가 응답에 bomb을 담아 보낼 수도 있다. 압축을 **해제하는 쪽**이라면 어느 방향이든 방어가 필요하다.

---

## Go 서버에서 gzip 요청 처리하기

Go의 `net/http`는 **응답 압축 해제는 자동으로 해주지만, 요청 압축 해제는 안 해준다.** [이전 글](/2026/03/07/http-gzip-compression)에서 봤듯이 Transport가 `gzipReader`로 응답을 투명하게 풀어줬던 것과 달리, 서버 쪽은 수동이다.

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

## OpenRTB에서의 활용

요청 압축이 가장 활발하게 쓰이는 곳 중 하나가 **OpenRTB(Real-Time Bidding)**다.

SSP(Supply-Side Platform)가 DSP(Demand-Side Platform)에게 bid request를 보낼 때, JSON payload를 gzip으로 압축해서 전송한다. 왜 이게 의미 있는가:

- bid request payload가 consent string, 복수 EID 등으로 **점점 커지는 추세**다
- JSON 기준 gzip으로 보통 **60~80% 크기 감소** (3x~6x 압축률)
- 하루 수억 건 × 수 KB 절감 = **상당한 네트워크 비용 차이** (AWS는 egress에 GB 단위 과금)

OpenRTB 2.5/2.6 스펙은 gzip 압축을 명시적으로 다룬다:

- **요청 압축**: SSP가 `Content-Encoding: gzip`으로 bid request를 압축. **사전에 DSP와 합의 필요**
- **응답 압축**: SSP가 `Accept-Encoding: gzip`을 보내면 DSP가 알아서 압축 응답. 별도 합의 불필요 — 일반 HTTP 협상과 동일

### 실제 플랫폼별 정책

플랫폼마다 기본값과 활성화 방식이 다르다.

| 플랫폼 | 요청 압축 | 기본값 | 활성화 방법 |
|---|---|---|---|
| **Smaato** | 필수 | 항상 압축 | 신규 파트너 전원 필수 |
| **InMobi** | 필수 | 항상 압축 | opt-out 불가 |
| **OpenX** | 선택 | 비압축 | Platform Development Manager에 요청 |
| **Index Exchange** | 선택 | 비압축 | Index 담당자에 요청 |
| **BidSwitch** | 선택 | 비압축 | support@bidswitch.com |
| **PubMatic** | 선택 | 비활성 | rtbops@pubmatic.com |

공통 패턴이 보인다:

- **모든 플랫폼**이 `Accept-Encoding: gzip`을 bid request에 항상 포함한다 → DSP는 별도 합의 없이 gzip 응답 가능
- **요청 압축**은 사전 합의가 필요하다 — 대부분 담당자에게 연락해서 활성화
- BidSwitch는 압축 활성화 후에도 **일부 요청이 비압축으로 올 수 있다**고 명시한다 → DSP는 `Content-Encoding` 헤더 유무를 반드시 체크해야 한다

### 브라우저 환경의 제약 — Prebid.js

서버 간 통신에서는 `Content-Encoding: gzip`을 자유롭게 쓸 수 있다. 그런데 **브라우저**에서는 상황이 다르다.

`Content-Encoding`은 CORS safelisted request header가 아니다. 브라우저에서 이 헤더를 설정하면 **preflight(OPTIONS) 요청**이 추가로 발생한다. RTB에서 이 추가 왕복은 치명적이다.

Prebid.js는 이를 우회하기 위해:
- `Content-Encoding` 헤더 대신 **`?gzip=1` 쿼리 파라미터**로 압축 여부를 알린다
- `Content-Type`도 `text/plain`으로 바꿔서 CORS simple request를 유지한다

### 대안: Protocol Buffers

OpenRTB 3.0은 JSON 외에 Protocol Buffers 같은 바이너리 포맷도 지원한다. 압축 없이도 JSON보다 작고, 직렬화/역직렬화 CPU도 적다. Google Authorized Buyers는 고빈도 환경에서 ProtoBuf를 권장한다.

---

## 정리

| 구분 | 응답 압축 | 요청 압축 |
|---|---|---|
| 헤더 | `Accept-Encoding` → `Content-Encoding` | `Content-Encoding`만 |
| 협상 | 사전 (`Accept-Encoding`) | 사후 (415 + API 문서) |
| 서버 지원 | 거의 모든 서버 | Apache, Express 등 일부만 |
| 보안 | decompression bomb 가능 | decompression bomb 가능 |
| 주요 사용처 | 웹 전반 | 서비스 간 통신 (OpenRTB, gRPC, OTLP) |

요청 압축은 응답 압축만큼 보편적이지 않지만, **대용량 JSON을 대량으로 주고받는 서비스 간 통신**에서는 의미 있는 최적화다. 서버가 지원하는지 확인하고, decompression bomb 방어를 반드시 구현해야 한다는 점만 기억하면 된다.
