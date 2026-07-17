---
title: "세션 스토어로 Redis를 쓸 때 고려할 것들"
url: "/backend/redis/2026/01/24/redis-session/"
date: 2026-01-24 15:00:00 +0900
categories: [backend, redis]
draft: true
---

서버를 무상태로 만들려고 세션을 Redis로 옮기고 나면, 진짜 문제는 그다음에 나온다. 보안과 TTL, 그리고 만료 시점을 어떻게 다루느냐다.

## 세션 키/값 설계

| 항목 | 설계 |
|------|------|
| **키** | `session:{sessionId}` 또는 `session:{userId}:{sessionId}` |
| **값** | 직렬화된 프로필/권한 (최소한의 정보, PII 최소화) |
| **포맷** | JSON (편리) / MessagePack, Protobuf (compact/fast) |
| **TTL** | 로그인 시 설정 (예: 30m~2h) |

## Python Flask 예시

```python
from flask import Flask, request, jsonify
import redis, uuid, json

app = Flask(__name__)
r = redis.Redis(host="localhost", port=6379, db=0)
SESSION_TTL = 3600

@app.post("/login")
def login():
    data = request.get_json(force=True)
    username, password = data.get("username"), data.get("password")
    if not authenticate(username, password):
        return jsonify({"error": "invalid credentials"}), 401

    sid = str(uuid.uuid4())
    profile = {"user_id": user_id(username), "name": username}
    # 값 설정 + TTL을 한 번에
    r.set(f"session:{sid}", json.dumps(profile), ex=SESSION_TTL, nx=True)

    resp = jsonify({"message": "ok"})
    resp.set_cookie("sid", sid, httponly=True, secure=True, samesite="Lax")
    return resp

@app.get("/me")
def me():
    sid = request.cookies.get("sid")
    if not sid:
        return jsonify({"error": "unauthorized"}), 401
    data = r.get(f"session:{sid}")
    if not data:
        return jsonify({"error": "expired"}), 401
    # 슬라이딩 TTL
    r.expire(f"session:{sid}", SESSION_TTL)
    return jsonify(json.loads(data))

@app.post("/logout")
def logout():
    sid = request.cookies.get("sid")
    if sid:
        r.delete(f"session:{sid}")
    resp = jsonify({"message": "bye"})
    resp.delete_cookie("sid")
    return resp
```

## 보안

| 항목 | 대응 |
|------|------|
| 쿠키 옵션 | `Secure` + `HttpOnly` + `SameSite` |
| 세션 고정(Fixation) | 로그인/권한 상승 시 **새 sid 발급** 후 기존 폐기 |
| CSRF | SameSite=Lax/Strict 또는 CSRF 토큰 병행 |
| 하이재킹/무차별 대입 | sid 길이/엔트로피 확보 (랜덤 128bit 이상, UUID4) |
| IP 변경 감지 | 세션에 IP 저장, 변경 시 재인증 요구 |
| PII | 평문 저장 금지, 최소 정보만 |

IP 변경 감지처럼 값 검증이 필요한 경우, 조회 시점에 함께 확인한다.

```python
def validate_session(sid: str, request_ip: str) -> bool:
    raw = redis.get(f"session:{sid}")
    if raw is None:
        return False  # 세션 만료 또는 존재하지 않음
    session = json.loads(raw)
    if session.get("ip") != request_ip:
        redis.delete(f"session:{sid}")
        return False
    return True
```

## TTL 전략

| 전략 | 설명 | 사용 시점 |
|------|------|----------|
| **슬라이딩** | 활동 시마다 연장 | 웹 로그인 유지 |
| **고정** | 무조건 만료 시점까지 | 토큰/단기 인증 |
| **블랙리스트** | 로그아웃/탈퇴 시 무효화 | 다중 세션 강제 로그아웃 |

## 만료 이벤트는 정시에 오지 않는다

강제 로그아웃 같은 후속 작업을 만료 이벤트로 걸고 싶을 때가 있다.

```redis
CONFIG SET notify-keyspace-events Ex
PSUBSCRIBE "__keyevent@0__:expired"
```

단, Redis의 expired 이벤트는 lazy expiry(접근 시 만료 확인) 또는 active expiry(백그라운드 주기적 스캔)에 의존하므로 **정확한 만료 시점에 즉시 발생하지 않을 수 있다.** 실시간 보장이 필요한 로직에는 적합하지 않다.

## 분산 환경에서의 일관성

세션 데이터는 **결과적 일관성**(Eventual Consistency)으로 처리해도 된다.

```
[요청 1] → Master → 쓰기 성공
[요청 2] → Replica → 아직 복제 안 됨 → 이전 데이터
```

대부분의 세션 조회는 복제본 읽기로도 문제없다. 복제 지연(~ms)이 문제가 되면 로그인/로그아웃은 마스터에서만 처리하고, 정합성이 중요한 구간에만 `WAIT`으로 복제 완료를 기다린다(성능 저하 감수). 클러스터라면 해시태그(`session:{user:123}:abc123`)로 동일 사용자 세션을 한 슬롯에 모을지 결정한다.

## 흔한 실수

| 실수 | 해결 |
|------|------|
| `SET` 후 `EXPIRE` 따로 호출 → TTL 유실 | `SET ... EX` 또는 Lua로 원자 처리 |
| 세션에 과도한 데이터 저장 (장바구니 등) | 별도 스토어/캐시 분리 |
| 쿠키에 민감 정보 포함 | sid만 보관, 서버에 상태 저장 |

## 모니터링 지표

- `used_memory`, `connected_clients`
- `expired_keys`, `evicted_keys`
- 세션 미스율을 추적하여 TTL 정책 조정에 활용한다

---

## 참고자료

- [OWASP - Session Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html)
- [Redis - Strings](https://redis.io/docs/latest/develop/data-types/strings/)
- [Flask - Sessions](https://flask.palletsprojects.com/en/stable/quickstart/#sessions)
- [Redis - EXPIRE](https://redis.io/docs/latest/commands/expire/)
