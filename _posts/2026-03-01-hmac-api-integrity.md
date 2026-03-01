---
layout: single
title: "외부 업체에 API를 열어줄 때, 요청이 조작되지 않았음을 어떻게 보장할까"
date: 2026-03-01 18:00:00 +0900
categories: [backend, security]
---

> 외부 업체에 포인트 지급 API를 열어줘야 한다. 인증 토큰은 이미 있다. 그런데 누군가 중간에서 `amount: 100`을 `amount: 10000`으로 바꾸면? 토큰은 여전히 유효하다. 이 글은 그 문제를 해결하는 HMAC에 대한 이야기다.

---

## 인증 토큰만으로는 안 되는 이유

API 키나 Bearer 토큰은 **"누구인가"**만 증명한다. 요청 본문이 도중에 바뀌었는지는 전혀 알 수 없다.

```
[연동사 서버] ---> amount: 100 ---> [중간자] ---> amount: 10000 ---> [우리 서버]
                                      ↑
                              토큰은 건드리지 않음
                              본문만 조작
```

우리 서버 입장에서는 유효한 토큰 + 정상적인 JSON이 들어온 것이다. 거부할 근거가 없다.

---

## HMAC: 메시지에 자물쇠를 채우는 방법

HMAC은 **H**ash-based **M**essage **A**uthentication **C**ode의 약자다.

핵심 아이디어는 단순하다: **비밀 키와 메시지를 함께 해싱**한다. 키를 모르는 사람은 올바른 해시값을 만들 수 없으므로, 수신 측에서 메시지가 조작되지 않았음을 검증할 수 있다.

```
발신: HMAC-SHA256(비밀키, 메시지) → 서명값 생성 → 메시지와 함께 전송
수신: 같은 방식으로 서명값 재계산 → 받은 서명값과 비교 → 일치하면 통과
```

단순 해시(`SHA256(메시지)`)와 다른 점은 **비밀 키**가 들어간다는 것이다. 해시는 누구나 계산할 수 있지만, HMAC은 키를 아는 당사자만 계산할 수 있다.

HMAC이 보장하는 것과 보장하지 않는 것을 명확히 하자:

| 보장하는 것 | 보장하지 않는 것 |
|---|---|
| 메시지 무결성 (1바이트라도 바뀌면 감지) | 기밀성 (메시지 자체는 평문) |
| 발신자 인증 (키 소유자만 생성 가능) | 부인 방지 (법적으로 누가 보냈는지 증명) |

기밀성이 필요하면 TLS 위에서 HMAC을 쓰면 된다. 대부분의 API 연동이 이 구조다.

---

## 실제 API 연동 흐름

외부 업체와 HMAC 기반 API를 연동할 때의 일반적인 프로토콜이다.

```mermaid
sequenceDiagram
    participant C as 연동사 서버
    participant S as 우리 서버

    Note over C: 1. 서명 대상 조립<br/>payload = method + path<br/>+ timestamp + body
    Note over C: 2. HMAC 생성<br/>sig = HMAC-SHA256(secret, payload)

    C->>S: POST /api/points<br/>X-Signature: {sig}<br/>X-Timestamp: {ts}<br/>Body: {"user_id":1, "amount":100}

    Note over S: 3. 타임스탬프 검증 (5분 이내?)
    Note over S: 4. 동일 방식으로 HMAC 재계산
    Note over S: 5. 서명 비교

    alt 일치
        S-->>C: 200 OK
    else 불일치 or 만료
        S-->>C: 401 Unauthorized
    end
```

여기서 **타임스탬프**가 중요하다. 서명에 타임스탬프를 포함시키고 유효 시간(보통 5분)을 제한하지 않으면, 공격자가 과거의 유효한 요청을 그대로 다시 보내는 **리플레이 공격**이 가능해진다.

이 패턴은 업계 표준이다. Stripe, GitHub, Shopify, Slack, AWS 모두 HMAC-SHA256 기반 Webhook 서명을 사용한다.

---

## Go로 구현하기

Go의 `crypto/hmac` 패키지를 쓰면 코드가 놀라울 정도로 짧다.

### 서명 생성

```go
func generateHMAC(key, message []byte) string {
    mac := hmac.New(sha256.New, key)
    mac.Write(message)
    return hex.EncodeToString(mac.Sum(nil))
}
```

`mac.Sum(nil)`은 "지금까지 Write한 데이터의 HMAC 값을 새 바이트 슬라이스로 돌려달라"는 뜻이다. `Sum`의 인자는 결과를 append할 대상인데, `nil`이면 새로 만든다.

### 서명 검증

```go
func verifyHMAC(key, message []byte, receivedSig string) bool {
    expectedSig := generateHMAC(key, message)
    return hmac.Equal([]byte(expectedSig), []byte(receivedSig))
}
```

**여기서 `hmac.Equal`을 반드시 써야 한다.** `==`이나 `bytes.Equal`을 쓰면 안 된다.

이유는 타이밍 공격 때문이다:

```
bytes.Equal은 첫 번째 불일치 바이트에서 즉시 false를 반환한다.

시도 1: [00]xxx → 0.1ms에 실패 (첫 바이트부터 틀림)
시도 2: [a3]xxx → 0.2ms에 실패 (첫 바이트 맞고 두 번째에서 틀림)
시도 3: [a3][f2]xxx → 0.3ms에 실패 ...

응답 시간 차이를 측정하면 한 바이트씩 HMAC을 맞춰나갈 수 있다.
```

`hmac.Equal`은 항상 전체 바이트를 비교(constant-time comparison)하므로 결과와 무관하게 동일한 시간이 걸린다.

### HTTP 미들웨어 예시

실제 서비스에서는 미들웨어로 빼는 게 일반적이다:

```go
func HMACMiddleware(secret []byte) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            sig := r.Header.Get("X-Signature")
            ts := r.Header.Get("X-Timestamp")

            // 타임스탬프 검증 (5분)
            reqTime, err := strconv.ParseInt(ts, 10, 64)
            if err != nil || time.Since(time.Unix(reqTime, 0)) > 5*time.Minute {
                http.Error(w, "request expired", http.StatusUnauthorized)
                return
            }

            // 본문 읽기
            body, _ := io.ReadAll(r.Body)
            r.Body = io.NopCloser(bytes.NewReader(body))

            // 서명 대상: method + path + timestamp + body
            payload := fmt.Sprintf("%s%s%s%s", r.Method, r.URL.Path, ts, body)

            if !verifyHMAC(secret, []byte(payload), sig) {
                http.Error(w, "invalid signature", http.StatusUnauthorized)
                return
            }

            next.ServeHTTP(w, r)
        })
    }
}
```

---

## 키 관리: HMAC의 아킬레스건

HMAC의 보안은 전적으로 비밀 키에 의존한다. 키가 유출되면 HMAC은 무력화된다.

### 키가 유출되면

1. **즉시 해당 키를 무효화한다.** 서버에서 해당 키로 들어오는 요청을 전부 거부한다.
2. **새 키를 안전한 채널로 전달한다.** 이메일이 아니라 별도 암호화 통신이나 오프라인으로.
3. **유예 기간을 둔다.** 구/신 키를 동시에 허용하는 짧은 기간(예: 24시간)을 설정해 서비스 중단을 방지한다.
4. **로그를 감사한다.** 유출 시점 전후의 요청을 전수 검토해 위변조된 요청이 실제로 처리되지 않았는지 확인한다.

키 유출을 사후 대응하는 것보다 **정기 로테이션**(예: 90일)을 미리 잡아두는 게 훨씬 낫다. 유출이 있더라도 피해 범위가 로테이션 주기로 제한된다.

---

## 정리

외부 업체에 API를 열어줄 때 인증 토큰만으로는 메시지 위변조를 막을 수 없다. HMAC은 비밀 키 + 해시 함수 조합으로 이 문제를 해결하며, 구현은 Go 기준 10줄이면 충분하다.

기억할 것 세 가지:

1. **서명 대상에 타임스탬프를 포함시켜라.** 리플레이 공격 방지.
2. **비교는 반드시 `hmac.Equal`로.** 타이밍 공격 방지.
3. **키 로테이션을 정기적으로.** 유출 피해 범위 제한.

---

**참고 자료**
- [Go crypto/hmac 공식 문서](https://pkg.go.dev/crypto/hmac)
- [RFC 2104 - HMAC: Keyed-Hashing for Message Authentication](https://datatracker.ietf.org/doc/html/rfc2104)
