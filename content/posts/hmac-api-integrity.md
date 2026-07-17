---
title: "토큰이 있어도 요청 본문은 바뀔 수 있다"
url: "/backend/security/2026/03/01/hmac-api-integrity/"
date: 2026-03-01 18:00:00 +0900
categories: [backend, security]
---

API 키나 Bearer 토큰은 "누가 보냈는가"를 확인한다. 하지만 요청 본문이 중간에서 바뀌었는지는 확인하지 못한다. `amount: 100`이 `amount: 10000`으로 바뀌어도 토큰 자체는 여전히 유효하다.

HMAC은 이 빈틈을 막기 위해 요청 본문까지 서명한다.

## HMAC이 보장하는 것

HMAC은 비밀 키와 메시지를 함께 해시해 서명을 만든다.

```text
signature = HMAC-SHA256(secret, message)
```

수신자는 같은 secret과 message로 서명을 다시 계산하고, 받은 서명과 비교한다. 1바이트라도 바뀌면 결과가 달라진다.

| 보장 | 설명 |
|---|---|
| 무결성 | 메시지가 바뀌면 검증 실패 |
| 발신자 인증 | secret을 아는 쪽만 유효한 서명 생성 |
| replay 방어 | timestamp나 nonce를 포함할 때 가능 |

HMAC은 암호화가 아니다. 본문을 숨기지는 않는다. 기밀성은 TLS가 맡고, HMAC은 위변조 검증을 맡는다.

## 서명 대상

서명 대상은 양쪽이 정확히 같은 문자열로 만들어야 한다. 보통 method, path, timestamp, raw body를 묶는다.

```text
payload = method + "\n" + path + "\n" + timestamp + "\n" + raw_body
signature = HMAC-SHA256(secret, payload)
```

중요한 점은 raw body다. JSON을 파싱했다가 다시 직렬화하면 공백, key 순서, escape 방식이 바뀔 수 있다. 서명 검증은 네트워크로 받은 원본 바이트 기준으로 하는 편이 안전하다.

timestamp도 서명 대상에 넣는다. 그렇지 않으면 공격자가 과거의 정상 요청을 그대로 다시 보내는 replay 공격을 할 수 있다.

## Go 예시

```go
func sign(secret, payload []byte) []byte {
    mac := hmac.New(sha256.New, secret)
    mac.Write(payload)
    return mac.Sum(nil)
}

func verify(secret, payload []byte, receivedHex string) bool {
    received, err := hex.DecodeString(receivedHex)
    if err != nil {
        return false
    }
    expected := sign(secret, payload)
    return hmac.Equal(expected, received)
}
```

비교에는 `hmac.Equal`을 쓴다. 일반 문자열 비교는 첫 번째로 다른 바이트에서 빨리 끝날 수 있어 timing attack의 단서가 된다.

HTTP 미들웨어에서는 대략 이런 순서로 처리한다.

```go
body, err := io.ReadAll(r.Body)
if err != nil {
    http.Error(w, "bad body", http.StatusBadRequest)
    return
}
r.Body = io.NopCloser(bytes.NewReader(body))

ts := r.Header.Get("X-Timestamp")
sig := r.Header.Get("X-Signature")

if expired(ts, 5*time.Minute) {
    http.Error(w, "expired", http.StatusUnauthorized)
    return
}

payload := buildPayload(r.Method, r.URL.Path, ts, body)
if !verify(secret, payload, sig) {
    http.Error(w, "invalid signature", http.StatusUnauthorized)
    return
}
```

검증 뒤 handler가 body를 다시 읽어야 하므로 `r.Body`를 복원해둔다.

## 운영에서 빠뜨리기 쉬운 것

- secret은 파트너별로 분리한다.
- key id를 헤더에 넣어 어떤 secret으로 검증할지 찾는다.
- timestamp 허용 창을 짧게 둔다.
- 필요하면 nonce나 request id를 저장해 replay를 한 번 더 막는다.
- 키 로테이션 기간에는 구 키와 신 키를 함께 허용한다.
- 실패 로그에 secret이나 전체 signature를 남기지 않는다.

HMAC의 강도는 secret 관리에 달려 있다. 키가 유출되면 공격자는 정상 서명을 만들 수 있다. 정기 로테이션과 유출 시 폐기 절차가 API 계약에 포함되어야 한다.

## 남는 기준

토큰은 호출자를 인증하고, HMAC은 메시지를 인증한다. 외부 파트너가 돈, 포인트, 주문 상태처럼 중요한 변경 API를 호출한다면 둘을 함께 쓰는 편이 안전하다.

## 참고자료

- [Go crypto/hmac](https://pkg.go.dev/crypto/hmac)
- [RFC 2104 - HMAC](https://datatracker.ietf.org/doc/html/rfc2104)
- [Stripe webhook signatures](https://docs.stripe.com/webhooks/signature)
