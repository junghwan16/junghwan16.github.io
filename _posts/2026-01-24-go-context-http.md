---
layout: post
title: "Go context와 HTTP 요청 종료"
date: 2026-01-24 13:00:00 +0900
categories: [backend, go]
---

Go의 HTTP 서버에서 "요청 종료"란, 클라이언트와의 연결이 끊기거나 요청 처리가 완료되어 해당 요청의 context가 취소(cancel)되는 것을 의미합니다.

## http.Request.Context()의 동작 방식

Go 1.7부터 `http.Request`는 `Context()` 메서드를 제공합니다.

```go
func handler(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    // 이 ctx는 요청이 끝나면 자동으로 취소된다
}
```

이 context는 다음 상황에서 **자동으로 취소**됩니다:

1. **클라이언트가 연결을 끊었을 때** (브라우저 탭 닫기, 네트워크 끊김 등)
2. **ServeHTTP 메서드가 반환될 때**
3. **HTTP/2 스트림이 닫힐 때**

## 클라이언트 연결 종료 감지

```go
func slowHandler(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()

    select {
    case <-time.After(10 * time.Second):
        fmt.Fprintln(w, "작업 완료")
    case <-ctx.Done():
        // 클라이언트가 연결을 끊음
        log.Println("클라이언트 연결 종료:", ctx.Err())
        return
    }
}
```

`ctx.Done()` 채널은 context가 취소되면 닫힙니다. 이를 통해:
- 불필요한 작업을 조기 종료
- 리소스 낭비 방지

## 실제 활용: DB/Redis 작업 취소

```go
func getUserHandler(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()

    // HTTP 요청 context를 Redis 호출에 전달
    val, err := rdb.Get(ctx, "user:123").Result()
    if err == context.Canceled {
        // 클라이언트가 이미 떠남 - 결과를 보낼 필요 없음
        return
    }
    // ...
}
```

클라이언트가 응답을 기다리지 않는다면, 백엔드도 작업을 계속할 이유가 없습니다. context 전파를 통해 "불필요한 작업"을 자동으로 취소할 수 있습니다.

## context 전파 패턴

```
HTTP 요청 context
 └─ 서비스 레이어 context
     ├─ DB 쿼리 context
     └─ Redis 호출 context
```

상위 context가 취소되면 하위 context도 **모두 취소**됩니다.

이것이 go-redis 등 라이브러리가 모든 API에서 `context.Context`를 요구하는 이유입니다.

## 주의사항

### BaseContext와 ConnContext

서버 설정에서 context를 커스터마이징할 수 있습니다:

```go
server := &http.Server{
    BaseContext: func(l net.Listener) context.Context {
        // 모든 요청의 기본 context
        return context.WithValue(context.Background(), "server", "main")
    },
    ConnContext: func(ctx context.Context, c net.Conn) context.Context {
        // 각 연결별 context
        return context.WithValue(ctx, "conn", c.RemoteAddr())
    },
}
```

### 백그라운드 작업은 별도 context 사용

```go
func handler(w http.ResponseWriter, r *http.Request) {
    // 요청과 무관하게 실행되어야 하는 작업
    go func() {
        // r.Context()를 쓰면 안 됨! 요청 종료 시 취소됨
        ctx := context.Background()
        doBackgroundWork(ctx)
    }()

    fmt.Fprintln(w, "작업이 백그라운드에서 실행됩니다")
}
```

요청 종료 후에도 계속 실행되어야 하는 작업은 `context.Background()`나 별도의 context를 사용해야 합니다.

## 정리

| 상황 | context 동작 |
|------|-------------|
| 클라이언트 연결 끊김 | 자동 취소 |
| ServeHTTP 반환 | 자동 취소 |
| HTTP/2 스트림 닫힘 | 자동 취소 |
| 백그라운드 작업 | `context.Background()` 사용 |

context 전파를 통해 클라이언트가 떠난 후 불필요한 DB/Redis 작업을 자동으로 취소할 수 있습니다. 모든 I/O 작업에 context를 전달하는 것을 습관화하세요.
