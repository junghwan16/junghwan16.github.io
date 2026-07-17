---
title: "Go 에러는 호출자와 디버거를 동시에 봐야 한다"
url: "/backend/go/2026/04/14/go-error-handling/"
date: 2026-04-14 10:00:00 +0900
categories: [backend, go]
---

Go 에러 처리는 `if err != nil { return err }`에서 끝나지 않는다. 운영 중에 필요한 건 두 가지다. 호출자는 "이 에러를 어떻게 분기해야 하는가"를 알아야 하고, 디버거는 "어디서 어떤 값으로 실패했는가"를 알아야 한다.

둘 중 하나만 만족하면 문제가 생긴다. 메시지만 풍부하면 호출자가 분기할 수 없고, sentinel만 던지면 장애 분석에 필요한 맥락이 사라진다.

## 기준

| 목적 | 필요한 정보 | Go 도구 |
|---|---|---|
| 호출자 분기 | 어떤 종류의 실패인가 | sentinel error, `errors.Is` |
| 데이터 추출 | 어떤 필드/값이 문제인가 | typed error, `errors.As` |
| 장애 분석 | 어느 레이어에서 어떤 입력으로 실패했는가 | `%w` 래핑 |
| HTTP 응답 | 내부 에러를 어떤 상태 코드로 바꿀 것인가 | 경계에서 매핑 |

핵심은 에러 체인을 보존하면서, 외부에 드러낼 계약은 좁게 유지하는 것이다.

## `%w`를 기본으로 쓴다

`fmt.Errorf`에서 `%v`와 `%w`는 출력만 보면 비슷하다. 하지만 `%v`는 원본 에러를 문자열로 바꾸고, `%w`는 에러 체인을 유지한다.

```go
var ErrUserNotFound = errors.New("user not found")

func (r *UserRepo) FindByID(ctx context.Context, id int64) (*User, error) {
    user, err := r.query(ctx, id)
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return nil, fmt.Errorf("find user %d: %w", id, ErrUserNotFound)
        }
        return nil, fmt.Errorf("find user %d: %w", id, err)
    }
    return user, nil
}
```

이렇게 하면 위쪽 레이어는 `errors.Is(err, ErrUserNotFound)`로 분기할 수 있고, 로그에는 `find user 42: user not found`처럼 분석에 필요한 값이 남는다.

반대로 아래 코드는 피한다.

```go
return fmt.Errorf("find user %d: %v", id, ErrUserNotFound)
```

문자열은 남지만 체인은 끊긴다. 호출자는 더 이상 `ErrUserNotFound`를 찾을 수 없다.

## Sentinel과 타입 에러를 나눈다

분기만 필요하면 sentinel이면 충분하다.

```go
var (
    ErrUserNotFound     = errors.New("user not found")
    ErrPermissionDenied = errors.New("permission denied")
)
```

호출자는 `errors.Is`로 상황만 판단한다.

```go
switch {
case errors.Is(err, ErrUserNotFound):
    return http.StatusNotFound
case errors.Is(err, ErrPermissionDenied):
    return http.StatusForbidden
default:
    return http.StatusInternalServerError
}
```

에러 안의 데이터를 꺼내야 할 때만 타입 에러를 둔다.

```go
type ValidationError struct {
    Field   string
    Message string
}

func (e *ValidationError) Error() string {
    return e.Field + ": " + e.Message
}
```

```go
var verr *ValidationError
if errors.As(err, &verr) {
    writeValidationError(w, verr.Field, verr.Message)
    return
}
```

처음부터 모든 에러를 구조체로 만들면 호출자와 내부 구현이 강하게 묶인다. "분기할 것인가, 값을 꺼낼 것인가"를 먼저 정하면 형태도 자연스럽게 정해진다.

## 로그는 경계에서 한 번만 남긴다

안쪽 레이어가 에러를 로그하고 다시 반환하면, 같은 장애가 레이어 수만큼 중복 기록된다. repository와 service는 맥락을 붙여 반환하고, handler나 worker 같은 프로세스 경계에서 한 번만 로그한다.

```go
func (h *Handler) GetUser(w http.ResponseWriter, r *http.Request) {
    user, err := h.service.GetUser(r.Context(), id)
    if err != nil {
        if errors.Is(err, context.Canceled) {
            return
        }

        status, message := mapError(err)
        slog.Error("get user failed", "err", err, "path", r.URL.Path)
        http.Error(w, message, status)
        return
    }

    writeJSON(w, user)
}
```

`context.Canceled`는 클라이언트가 연결을 끊은 경우가 많다. 서버 장애처럼 로그와 알람을 남기면 지표가 오염된다. `context.DeadlineExceeded`는 보통 504나 재시도 판단으로 이어진다.

## HTTP 응답은 내부 에러와 분리한다

내부 에러 메시지를 그대로 클라이언트에게 보내면 구현 세부가 노출된다. 반대로 모든 에러를 500으로 보내면 클라이언트가 대응할 수 없다. 경계에서 에러 체인을 읽고 API 계약으로 바꾼다.

```go
func mapError(err error) (int, string) {
    switch {
    case errors.Is(err, ErrUserNotFound):
        return http.StatusNotFound, "user not found"
    case errors.Is(err, ErrPermissionDenied):
        return http.StatusForbidden, "permission denied"
    case errors.Is(err, context.DeadlineExceeded):
        return http.StatusGatewayTimeout, "timeout"
    default:
        return http.StatusInternalServerError, "internal server error"
    }
}
```

서비스 내부에서는 디버깅 가능한 에러를 만들고, 외부 경계에서는 안정적인 응답 계약으로 번역한다. 이 두 책임을 섞지 않는 것이 중요하다.

## 남는 규칙

- 원본 에러를 보존해야 하면 `%w`를 쓴다.
- 호출자가 상황만 분기하면 sentinel과 `errors.Is`를 쓴다.
- 호출자가 필드를 꺼내야 하면 타입 에러와 `errors.As`를 쓴다.
- 내부 레이어는 로그하지 말고 맥락을 붙여 반환한다.
- HTTP handler, worker loop, CLI main 같은 경계에서 한 번만 로그한다.
- context 에러는 일반 500과 분리한다.

좋은 에러 처리는 예외적인 장식이 아니라 운영 인터페이스다. 장애가 났을 때 호출자는 올바르게 분기하고, 사람은 로그 한 줄로 실패 지점을 좁힐 수 있어야 한다.
