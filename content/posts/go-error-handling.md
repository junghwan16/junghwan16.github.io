---
title: "Go 에러 처리 — 백엔드 개발자가 알아야 할 것들"
url: "/backend/go/2026/04/14/go-error-handling/"
date: 2026-04-14 10:00:00 +0900
categories: [backend, go]
---

새벽 3시에 알람이 울렸다. 슬랙에는 "결제 실패" 알림이 쏟아지고, 로그를 열었더니 이렇게 쓰여 있다.

```
ERROR: something went wrong
```

이게 어느 함수에서 나온 건지, 원인이 DB인지 네트워크인지, 재시도하면 되는지 아니면 데이터 자체가 문제인지 — 아무것도 알 수 없다.

Go의 에러 처리는 쉬워 보인다. `if err != nil { return err }`. 하지만 이게 전부라고 생각하면 프로덕션에서 반드시 이 상황을 만나게 된다. 이 글은 Go 에러 처리의 두 가지 역할을 구분하는 것에서 시작한다.

---

## 에러의 두 가지 역할

Go 에러는 동시에 두 종류의 독자를 위해 존재한다.

**호출자(caller)**: "이 에러가 어떤 종류인지" 알고 싶다. 파일이 없어서인가? 권한 문제인가? DB 연결이 끊어진 건가? 이 정보로 분기한다.

**디버거(debugger)**: "이 에러가 어디서 왜 발생했는지" 알고 싶다. 어떤 ID로 조회했는가? 어떤 쿼리가 실행됐는가? 어떤 레이어를 거쳐 올라왔는가? 이 정보로 사후 분석한다.

대부분의 Go 코드가 둘 중 하나만 제대로 한다. 두 역할을 명확히 이해하면 어떤 에러를 어떻게 처리해야 할지 자연스럽게 보인다.

---

## %w와 %v — 가장 흔한 실수

다음 두 줄의 차이를 알고 있는가?

```go
return fmt.Errorf("db.Query 실패: %w", err)
return fmt.Errorf("db.Query 실패: %v", err)
```

출력되는 에러 메시지는 똑같다. 하지만 동작은 완전히 다르다.

`%w`는 원본 에러를 **보존**한다. 에러 체인이 유지되므로 `errors.Is`와 `errors.As`가 안쪽 에러까지 탐색할 수 있다.

`%v`는 원본 에러를 **문자열로 태워버린다**. 체인이 끊기고, `errors.Is`와 `errors.As`는 바깥 에러만 본다.

```go
var ErrNotFound = errors.New("not found")

original := ErrNotFound
wrapped_w := fmt.Errorf("서비스 레이어: %w", original)
wrapped_v := fmt.Errorf("서비스 레이어: %v", original)

errors.Is(wrapped_w, ErrNotFound)  // true  — 체인 유지됨
errors.Is(wrapped_v, ErrNotFound)  // false — 체인이 끊겼다
```

`%v`로 래핑하는 순간 호출자는 이 에러가 `ErrNotFound`인지 알 방법이 없다. 코드 리뷰에서 눈에 잘 안 띄지만, 에러 처리 로직이 조용히 망가진다.

---

## 에러 래핑: 컨텍스트를 쌓아가는 기술

각 레이어는 에러에 자신이 알고 있는 컨텍스트를 추가해야 한다.

```go
// repository
func (r *UserRepo) FindByID(ctx context.Context, id int64) (*User, error) {
    var u User
    row := r.db.QueryRowContext(ctx, "SELECT * FROM users WHERE id = ?", id)
    if err := row.Scan(&u.ID, &u.Name, &u.Email); err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return nil, fmt.Errorf("user(%d) not found: %w", id, ErrUserNotFound)
        }
        return nil, fmt.Errorf("user(%d) scan failed: %w", id, err)
    }
    return &u, nil
}

// service
func (s *UserService) GetProfile(ctx context.Context, id int64) (*Profile, error) {
    user, err := s.repo.FindByID(ctx, id)
    if err != nil {
        return nil, fmt.Errorf("GetProfile: %w", err)
    }
    // ...
}

// handler
func (h *Handler) GetProfile(w http.ResponseWriter, r *http.Request) {
    profile, err := h.svc.GetProfile(r.Context(), id)
    if err != nil {
        // 여기서 에러 체인을 분석한다
    }
}
```

에러가 올라오면 체인은 이렇게 쌓인다.

```
GetProfile: user(42) not found: user not found
    ↑              ↑                   ↑
  service       repository          sentinel
```

새벽 3시에 이 메시지를 보면 어떤 ID로 어떤 레이어에서 무슨 일이 있었는지 바로 보인다.

---

## Sentinel 에러 vs 타입 에러

에러를 어떤 형태로 정의할지는 "호출자가 에러에서 무엇을 필요로 하는가"로 결정한다.

### 분기만 필요하다면 — Sentinel

```go
var (
    ErrUserNotFound    = errors.New("user not found")
    ErrPermissionDenied = errors.New("permission denied")
    ErrRateLimited     = errors.New("rate limited")
)
```

호출자는 `errors.Is`로 분기한다.

```go
if errors.Is(err, ErrUserNotFound) {
    return http.StatusNotFound, nil
}
if errors.Is(err, ErrPermissionDenied) {
    return http.StatusForbidden, nil
}
```

단순하고 명확하다. 과설계하지 않아도 된다.

### 에러 데이터가 필요하다면 — 타입 에러

호출자가 에러 안의 데이터를 꺼내야 할 때만 타입 에러를 쓴다.

```go
type ValidationError struct {
    Field   string
    Message string
}

func (e *ValidationError) Error() string {
    return fmt.Sprintf("validation failed: %s — %s", e.Field, e.Message)
}
```

```go
// errors.AsType — Go 1.26+
if verr, ok := errors.AsType[*ValidationError](err); ok {
    json.NewEncoder(w).Encode(map[string]string{
        "field":   verr.Field,
        "message": verr.Message,
    })
}

// errors.As — Go 1.13+ (AsType 이전 버전)
var verr *ValidationError
if errors.As(err, &verr) {
    json.NewEncoder(w).Encode(map[string]string{
        "field":   verr.Field,
        "message": verr.Message,
    })
}
```

타입 에러로 시작하면 호출자와 정의 사이에 결합도가 생긴다. 구조가 바뀌면 양쪽을 같이 수정해야 한다. 분기만 필요하다면 sentinel로 충분하다.

**기준 한 줄**: 호출자가 에러 내부 데이터를 꺼낼 필요가 없으면 sentinel, 꺼내야 하면 타입 에러.

---

## errors.Is와 errors.As — 목적으로 구분

이미 sentinel과 타입 에러를 구분했다면 Is/As의 선택은 자연스럽게 따라온다.

| | 질문 | 데이터 접근 | 쓰는 경우 |
|---|---|---|---|
| `Is` | "이 상황이 맞아?" | 불필요 | sentinel 비교, 분기 |
| `As` | "이 타입이야? 꺼내줘" | 필요 | 타입 에러에서 필드 추출 |

```go
// Is — 상황 판별
if errors.Is(err, context.DeadlineExceeded) {
    // 재시도 가능, 타임아웃이었다
}

// As — 데이터 추출 (Go 1.26+에서는 errors.AsType[net.Error](err))
var netErr net.Error
if errors.As(err, &netErr) {
    if netErr.Timeout() {
        retryAfter = 1 * time.Second
    }
}
```

`net.Error`는 `Timeout() bool`, `Temporary() bool` 같은 메서드를 가진 인터페이스다. `Is`로는 "network 에러야?"만 알 수 있고, 실제로 타임아웃인지 확인하려면 `As`로 꺼내야 한다.

---

## HTTP 서비스에서의 에러 처리 패턴

백엔드 서버의 핵심 과제는 내부 에러를 적절한 HTTP 응답으로 변환하는 것이다. 이를 잘못하면 두 가지 문제가 생긴다.

1. 모든 에러가 500이 된다 — 클라이언트가 대응할 수 없다.
2. 내부 에러 메시지가 그대로 클라이언트에 노출된다 — 정보 유출.

경계(handler)에서 한 번에 매핑하는 패턴이 효과적이다.

```go
func mapError(err error) (int, string) {
    switch {
    case errors.Is(err, ErrUserNotFound):
        return http.StatusNotFound, "사용자를 찾을 수 없습니다"
    case errors.Is(err, ErrPermissionDenied):
        return http.StatusForbidden, "권한이 없습니다"
    case errors.Is(err, ErrRateLimited):
        return http.StatusTooManyRequests, "요청이 너무 많습니다"
    case errors.Is(err, context.DeadlineExceeded):
        return http.StatusGatewayTimeout, "처리 시간이 초과되었습니다"
    default:
        return http.StatusInternalServerError, "서버 오류가 발생했습니다"
    }
}

func (h *Handler) handle(w http.ResponseWriter, r *http.Request) {
    result, err := h.svc.DoSomething(r.Context(), req)
    if err != nil {
        // context.Canceled: 클라이언트가 이미 끊었다 — 응답 불필요, 로그도 불필요
        if errors.Is(err, context.Canceled) {
            return
        }
        code, msg := mapError(err)
        // 내부 에러는 서버 로그에만
        slog.Error("request failed", "err", err, "path", r.URL.Path)
        http.Error(w, msg, code)
        return
    }
    // ...
}
```

`mapError` 함수는 에러 체인 안을 탐색(`errors.Is`)하므로, 에러가 몇 겹으로 래핑되어 있어도 올바른 HTTP 코드를 반환한다. 클라이언트에는 사람이 읽을 수 있는 메시지만, 서버 로그에는 전체 체인이 기록된다.

---

## errors.Join — 검증 에러를 한꺼번에

요청 검증처럼 여러 조건을 확인해야 할 때, 첫 번째 에러에서 바로 반환하면 클라이언트는 하나씩 수정하며 여러 번 요청해야 한다.

```go
func validateCreateUser(req CreateUserRequest) error {
    var errs []error

    if req.Name == "" {
        errs = append(errs, &ValidationError{Field: "name", Message: "필수 항목입니다"})
    }
    if !isValidEmail(req.Email) {
        errs = append(errs, &ValidationError{Field: "email", Message: "올바른 이메일 형식이 아닙니다"})
    }
    if len(req.Password) < 8 {
        errs = append(errs, &ValidationError{Field: "password", Message: "8자 이상이어야 합니다"})
    }

    return errors.Join(errs...)  // 모두 nil이면 nil 반환
}
```

`errors.Join`이 반환한 에러는 `Unwrap() []error`를 구현한다. `errors.Is`와 `errors.As`는 이 인터페이스를 처리하도록 구현되어 있어 내부를 올바르게 탐색한다.

```go
err := validateCreateUser(req)
if err != nil {
    // err.Error()는 각 메시지를 줄바꿈으로 연결한다
    // "이름이 비어있음\n이메일이 비어있음\n나이가 음수"
    http.Error(w, err.Error(), http.StatusBadRequest)
    return
}
```

**`errors.Unwrap`과의 차이 — 흔한 함정**

`errors.Unwrap`은 `Unwrap() error`(단일 체인)만 처리한다. `errors.Join`이 반환하는 에러는 `Unwrap() []error`를 구현하므로, `errors.Unwrap`을 호출하면 즉시 `nil`을 반환한다.

```go
joined := errors.Join(err1, err2)

errors.Unwrap(joined)        // nil — []error는 처리 안 됨
errors.Is(joined, err1)      // true — Is는 []error도 탐색함
errors.Is(joined, err2)      // true
```

`errors.Is`·`errors.As`는 내부적으로 `Unwrap() []error`를 처리하기 때문에 올바르게 동작한다. `errors.Unwrap`을 직접 써서 Join 결과를 순회하려 하면 첫 번째 반복에서 종료된다.

**구조화된 다중 에러가 필요하다면 — 커스텀 슬라이스 타입**

각 ValidationError의 `Field`, `Message`에 접근해야 한다면 `errors.Join` 대신 커스텀 타입을 쓴다. `errors.Join`은 sentinel 에러를 묶어 `Is`로 검사할 때 적합하다.

```go
type ValidationErrors []*ValidationError

func (ve ValidationErrors) Error() string {
    msgs := make([]string, len(ve))
    for i, e := range ve {
        msgs[i] = fmt.Sprintf("%s: %s", e.Field, e.Message)
    }
    return strings.Join(msgs, "\n")
}

// errors.As가 이 타입을 찾을 수 있도록 Unwrap 구현
func (ve ValidationErrors) Unwrap() []error {
    errs := make([]error, len(ve))
    for i, e := range ve {
        errs[i] = e
    }
    return errs
}
```

```go
// handler
var verrs ValidationErrors
if errors.As(err, &verrs) {
    w.WriteHeader(http.StatusBadRequest)
    json.NewEncoder(w).Encode(verrs)  // [{field, message}, ...]
}
```

---

## 자주 저지르는 실수

### 1. 에러를 로그하고 또 반환한다

```go
// 잘못된 패턴
func (r *UserRepo) FindByID(id int64) (*User, error) {
    user, err := r.db.Query(...)
    if err != nil {
        log.Errorf("db query failed: %v", err)  // 여기서 로그
        return nil, err                          // 그리고 반환
    }
    return user, nil
}

func (s *UserService) GetUser(id int64) (*User, error) {
    user, err := s.repo.FindByID(id)
    if err != nil {
        log.Errorf("repo error: %v", err)  // 또 로그
        return nil, err
    }
    return user, nil
}
```

에러 하나에 로그 두 개가 찍힌다. 레이어가 깊어질수록 곱셈으로 증가한다. 운영 로그가 중복으로 가득 찬다.

**원칙**: 에러는 **한 번만** 로그한다. 가장 바깥 경계(handler)에서 로그하고, 안쪽 레이어는 래핑만 한다.

```go
// 올바른 패턴
func (r *UserRepo) FindByID(id int64) (*User, error) {
    user, err := r.db.Query(...)
    if err != nil {
        return nil, fmt.Errorf("FindByID(%d): %w", id, err)  // 래핑만
    }
    return user, nil
}

func (h *Handler) GetUser(w http.ResponseWriter, r *http.Request) {
    user, err := h.svc.GetUser(id)
    if err != nil {
        slog.Error("GetUser failed", "err", err)  // 경계에서 한 번만 로그
        // ...
    }
}
```

### 2. errors.New를 비교에 직접 쓴다

```go
// 항상 false — New는 호출마다 새 인스턴스
if errors.Is(err, errors.New("not found")) { ... }
```

패키지 수준 변수로 선언하고 재사용해야 한다.

### 3. 패키지 내부 에러를 그대로 외부에 노출한다

```go
// user 패키지 내부 구현 에러
if err := r.db.Exec(...); err != nil {
    return err  // *mysql.MySQLError가 그대로 나간다
}
```

호출자는 `*mysql.MySQLError`를 직접 다뤄야 한다. 내부 구현을 바꾸면(PostgreSQL로 이관 등) 호출자 코드도 바꿔야 한다.

패키지 경계에서는 내부 에러를 도메인 에러로 변환한다.

```go
if err := r.db.Exec(...); err != nil {
    var mysqlErr *mysql.MySQLError
    if errors.As(err, &mysqlErr) && mysqlErr.Number == 1062 {
        return fmt.Errorf("이미 존재하는 이메일: %w", ErrDuplicateEmail)
    }
    return fmt.Errorf("db.Exec: %w", err)
}
```

### 4. context 에러를 무시한다

백엔드 서비스에서 `context.Canceled`와 `context.DeadlineExceeded`는 흔히 발생한다. HTTP 클라이언트가 연결을 끊거나, 타임아웃이 걸렸을 때다.

```go
// 문제: 취소된 요청도 그냥 500 처리
result, err := h.svc.Process(r.Context(), req)
if err != nil {
    http.Error(w, "error", 500)
    return
}
```

```go
// 개선: context 에러는 별도 처리
result, err := h.svc.Process(r.Context(), req)
if err != nil {
    if errors.Is(err, context.Canceled) {
        // 클라이언트가 끊었다 — 로그할 필요 없음, 알람 울리면 안 됨
        return
    }
    if errors.Is(err, context.DeadlineExceeded) {
        http.Error(w, "timeout", http.StatusGatewayTimeout)
        return
    }
    slog.Error("process failed", "err", err)
    http.Error(w, "server error", http.StatusInternalServerError)
}
```

`context.Canceled`를 서버 에러로 카운트하면 알람 임계값이 오염된다. 클라이언트가 능동적으로 연결을 끊은 것은 서버 에러가 아니다.

---

## 에러 처리를 설계로 보기

에러 처리는 보일러플레이트가 아니다. 에러 처리 방식이 곧 시스템의 디버거 친화성, API 계약, 레이어 간 결합도를 결정한다.

- `%w`로 래핑하면 디버거는 새벽 3시에도 문제를 찾을 수 있다.
- sentinel/타입 에러를 목적에 맞게 쓰면 호출자 코드가 명확해진다.
- 경계에서 한 번만 로그하면 운영 노이즈가 줄어든다.
- context 에러를 따로 처리하면 알람이 의미 있어진다.

각각은 작은 관습처럼 보이지만, 시스템이 커질수록 이 차이가 쌓여 "고장 났을 때 5분 안에 원인을 찾는 팀"과 "원인을 못 찾고 재시작하는 팀"을 만든다.
