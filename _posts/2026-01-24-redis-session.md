---
layout: post
title: "세션 스토어로 Redis를 쓸 때 고려할 것들"
date: 2026-01-24 15:00:00 +0900
categories: [backend, redis]
---

서버를 무상태로 만들고 싶다면 세션을 Redis로 옮기는 것이 일반적인 선택입니다. 하지만 보안과 TTL 전략을 놓치면 문제가 됩니다.

## 먼저 생각해볼 것

> - 서버가 여러 대인가? 세션 공유가 필요한가?
> - 세션에 어떤 정보를 저장할 것인가? (최소 정보만 권장)
> - 세션 만료 정책은? (고정 TTL vs 슬라이딩 TTL)
> - Redis 장애 시 로그인 세션은 어떻게 되는가?

## 왜 Redis 세션인가

- 서버를 **무상태(stateless)**로 만들어 수평 확장 단순화
- 인메모리라 빠르고, TTL로 자동 청소
- Sentinel/Cluster로 SPOF 제거 가능

## 세션 키/값 설계

| 항목 | 설계 |
|------|------|
| **키** | `session:{sessionId}` 또는 `session:{userId}:{sessionId}` |
| **값** | 직렬화된 프로필/권한 (최소한의 정보, PII 최소화) |
| **포맷** | JSON (편리) / MessagePack, Protobuf (compact/fast) |
| **TTL** | 로그인 시 설정 (예: 30m~2h) |

## 기본 흐름

```
1. 로그인 성공 → SET session:{sid} <json> EX 3600
2. 요청마다 쿠키/헤더로 sid 수신 → GET session:{sid}
3. 유효하면 (선택) EXPIRE session:{sid} 3600 으로 연장
4. 로그아웃 → DEL session:{sid}
```

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

## 보안 체크리스트

| 항목 | 대응 |
|------|------|
| 쿠키 옵션 | `Secure` + `HttpOnly` + `SameSite` |
| 세션 고정 방지 | 로그인/권한 상승 시 **새 sid 발급** 후 기존 폐기 |
| CSRF | SameSite=Lax/Strict 또는 CSRF 토큰 병행 |
| 탈취 방지 | sid 길이/엔트로피 충분 (랜덤 128bit 이상) |
| PII | 평문 저장 금지, 최소 정보만 |

## TTL 전략

| 전략 | 설명 | 사용 시점 |
|------|------|----------|
| **슬라이딩** | 활동 시마다 연장 | 웹 로그인 유지 |
| **고정** | 무조건 만료 시점까지 | 토큰/단기 인증 |
| **블랙리스트** | 로그아웃/탈퇴 시 무효화 | 다중 세션 강제 로그아웃 |

## 확장/운영 팁

### 키 스페이스 정리

```bash
# 세션 키 개수 확인
SCAN 0 MATCH session:* COUNT 1000
INFO keyspace
```

### 클러스터 환경

- 해시태그로 동일 사용자 세션을 한 슬롯에 모을지 결정
- 예: `session:{user:123}:abc123`

### 가용성

- 세션은 캐시 성격 → 복제본 읽기 허용 가능
- 쓰기는 마스터로
- Sentinel/Cluster로 자동 페일오버

### 만료 이벤트 구독

```redis
CONFIG SET notify-keyspace-events Ex
PSUBSCRIBE "__keyevent@0__:expired"
```

강제 로그아웃 등 실시간 후속 작업이 필요할 때 사용

## 흔한 실수

| 실수 | 해결 |
|------|------|
| `SET` 후 `EXPIRE` 따로 호출 → TTL 유실 | `SET ... EX` 또는 Lua로 원자 처리 |
| 세션에 과도한 데이터 저장 (장바구니 등) | 별도 스토어/캐시 분리 |
| 쿠키에 민감 정보 포함 | sid만 보관, 서버에 상태 저장 |

## 모니터링 지표

- `used_memory`, `connected_clients`
- `expired_keys`, `evicted_keys`
- 세션 미스율 → TTL 정책 조정에 활용

## 자가 체크

> - 쿠키에 `Secure`, `HttpOnly`, `SameSite` 옵션을 모두 설정했는가?
> - 로그인 시 새 세션 ID를 발급하고 이전 세션을 삭제하는가?
> - 세션에 비밀번호나 민감 정보를 저장하고 있지 않은가?
> - `SET` 후 `EXPIRE` 따로 호출하는 대신 `SET ... EX`를 쓰고 있는가?
