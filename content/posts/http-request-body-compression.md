---
title: "요청 Body도 gzip으로 보낼 수 있을까"
url: "/backend/network/2026/03/08/http-request-body-compression/"
date: 2026-03-08 09:00:00 +0900
categories: [backend, network]
---

응답만 압축할 수 있는 것은 아니다. 클라이언트가 request body를 gzip으로 압축해서 보낼 수도 있다. 이때도 헤더는 `Content-Encoding`이다.

```http
POST /api/events HTTP/1.1
Content-Type: application/json
Content-Encoding: gzip

<gzip compressed body>
```

`Content-Type`은 압축을 풀고 난 원본 형식이고, `Content-Encoding`은 전송 중 본문에 적용된 인코딩이다.

## 응답 압축과 다르다

응답 압축은 클라이언트가 먼저 협상한다.

```http
Accept-Encoding: gzip, br
```

서버는 가능한 방식으로 압축하고 `Content-Encoding`을 붙인다.

요청 압축은 사전 협상이 약하다. 클라이언트가 `Content-Encoding: gzip`을 붙여 보내고, 서버가 풀 수 없으면 거부한다. 그래서 실무에서는 API 문서나 파트너 계약으로 요청 압축 지원 여부를 정한다.

## 언제 의미가 있나

요청 압축은 모든 API에 필요하지 않다. 압축/해제 CPU 비용이 있고, 서버 구현도 직접 챙겨야 한다.

의미가 있는 경우는 대체로 이렇다.

- JSON body가 크다.
- 같은 구조의 요청이 대량으로 반복된다.
- 네트워크 비용이나 bandwidth가 병목이다.
- 클라이언트와 서버가 모두 압축 지원을 명확히 알고 있다.

로그 수집이나 이벤트 배치 전송처럼 큰 JSON을 초당 많이 주고받는 서버 간 통신이 대표적이다.

## 보안: 풀리는 크기를 제한한다

압축을 받는 쪽은 decompression bomb을 조심해야 한다. 작은 gzip body가 풀렸을 때 매우 큰 데이터가 될 수 있다.

방어는 두 단계가 필요하다.

- 압축된 request body 크기를 제한한다.
- 압축 해제 후 읽을 수 있는 최대 크기를 제한한다.

Go에서는 request body를 gzip reader로 감싸고, 다시 `io.LimitReader`로 제한한다.

```go
const maxBody = 10 << 20 // 10 MiB

func gunzipRequest(next http.Handler) http.Handler {
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

        r.Body = io.NopCloser(io.LimitReader(gz, maxBody+1))
        r.Header.Del("Content-Encoding")
        r.ContentLength = -1

        next.ServeHTTP(w, r)
    })
}
```

하위 handler는 압축을 모르게 두는 편이 좋다. 미들웨어 경계에서 해제하고, 이후에는 일반 JSON body처럼 처리한다.

## 테스트할 때

바이너리 body를 보낼 때는 `--data-binary`를 쓴다.

```bash
printf '{"id":"1","events":[{"id":"1"}]}' | gzip > /tmp/payload.json.gz

curl -X POST http://localhost:8080/events \
  -H 'Content-Type: application/json' \
  -H 'Content-Encoding: gzip' \
  --data-binary @/tmp/payload.json.gz
```

`-d`는 폼 전송에 맞춰 데이터를 다룰 수 있어 압축 바이너리 확인에는 부적합하다.

## 남는 기준

요청 압축은 "가능한가"보다 "양쪽이 명시적으로 합의했는가"가 중요하다. 응답 압축처럼 브라우저와 서버가 흔히 자동 협상해주는 기능이 아니다. 도입한다면 API 계약, 최대 크기 제한, decompression bomb 방어, 비압축 요청 처리 방식을 함께 정해야 한다.

## 참고자료

- [RFC 9110 Content-Encoding](https://www.rfc-editor.org/rfc/rfc9110#section-8.4)
- [RFC 9110 415 Unsupported Media Type](https://www.rfc-editor.org/rfc/rfc9110#section-15.5.16)
- [Go compress/gzip](https://pkg.go.dev/compress/gzip)
