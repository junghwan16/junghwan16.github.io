---
title: "Dynamo는 왜 DynamoDB가 되었나"
url: "/backend/infrastructure/2026/02/16/dynamo-to-dynamodb/"
date: 2026-02-16 21:00:00 +0900
categories: [backend, infrastructure]
---

Amazon의 Dynamo는 기술적으로 성공한 내부 분산 key-value store였다. 그런데 AWS가 외부에 내놓은 서비스는 Dynamo 자체가 아니라 DynamoDB였다. 이름은 이어받았지만, 운영 모델과 아키텍처는 크게 달라졌다.

핵심 이유는 하나다. **뛰어난 분산 시스템이라도 각 팀이 직접 운영해야 하면 널리 쓰이기 어렵다.**

## Dynamo가 푼 문제

2004년 연말 쇼핑 시즌, Amazon은 관계형 데이터베이스 장애를 겪었다. 많은 워크로드가 사실상 key-value 조회였는데도 복잡한 RDBMS 위에서 운영되고 있었다.

Dynamo는 이 문제를 위해 만들어졌다.

- key-value 중심 API
- consistent hashing 기반 분산
- N/R/W quorum 설정
- vector clock 기반 충돌 감지
- 장애 상황에서도 쓰기를 계속 받는 설계

장바구니나 세션처럼 항상 쓰기 가능성이 중요한 워크로드에 잘 맞았다.

## 문제는 운영이었다

Dynamo는 내부 팀이 직접 띄우고 운영하는 소프트웨어였다. 각 팀은 노드 구성, quorum 파라미터, 장애 처리, 리밸런싱, 복제, 용량 계획을 직접 다뤄야 했다.

분산 시스템을 잘 아는 팀에게는 강력했지만, 모든 제품팀이 그런 역량을 갖고 싶어 하지는 않았다.

Amazon 내부에는 기능이 더 제한적인 SimpleDB도 있었다. 그런데 일부 팀은 Dynamo 대신 관리형 서비스인 SimpleDB를 선택했다. 더 강력한 시스템보다 운영 부담이 작은 시스템을 고른 것이다.

이 선택이 중요한 신호였다. 개발자들이 원한 것은 "Dynamo를 설치할 자유"가 아니라 "테이블을 만들면 알아서 확장되는 서비스"였다.

## 충돌 해결도 현실과 부딪혔다

Dynamo의 벡터 클럭은 충돌을 감지하고, 애플리케이션이 비즈니스 로직에 맞게 병합할 수 있게 한다. 이론적으로는 좋은 모델이다.

하지만 현실에서는 많은 애플리케이션이 충돌 해결 로직을 제대로 구현하고 싶어 하지 않는다. 장바구니처럼 병합 규칙이 분명한 경우도 있지만, 대부분의 서비스는 단순한 정책을 원한다.

DynamoDB는 이 방향을 받아들였다. 클라이언트가 충돌 해결을 떠안는 모델보다, 서버 측 정책과 강한 일관성 읽기 옵션을 제공하는 쪽으로 갔다.

## DynamoDB는 같은 시스템의 포장이 아니다

DynamoDB는 Dynamo의 외부 공개판이라기보다, Dynamo의 교훈을 바탕으로 새로 설계한 관리형 서비스에 가깝다.

| 항목 | Dynamo | DynamoDB |
|---|---|---|
| 운영 모델 | 팀별 자체 운영 | AWS 완전관리형 |
| 일관성 | 최종 일관성 중심 | 최종 일관성 + 강한 일관성 읽기 옵션 |
| 충돌 처리 | 클라이언트 측 vector clock | 서버 측 정책 중심 |
| 멤버십/용량 | 사용 팀이 관리 | 서비스가 관리 |
| 사용자 경험 | 분산 시스템 운영 | 테이블과 API 사용 |

분산 시스템의 내부 제어권을 줄인 대신, 운영 부담을 서비스가 흡수했다.

## 남는 교훈

DynamoDB가 나온 이유는 Dynamo가 실패했기 때문이 아니다. 오히려 Dynamo가 내부에서 증명한 확장성과 지연시간 특성을, 더 많은 개발자가 쓸 수 있는 형태로 바꿀 필요가 있었기 때문이다.

관리형 서비스의 가치는 기능을 더하는 데만 있지 않다. 사용자가 직접 알아야 하는 분산 시스템의 세부사항을 줄이는 데 있다.

## 참고자료

- [A Decade of Dynamo](https://www.allthingsdistributed.com/2017/10/a-decade-of-dynamo.html)
- [Amazon DynamoDB launch post](https://www.allthingsdistributed.com/2012/01/amazon-dynamodb.html)
- [Amazon DynamoDB: A Scalable, Predictably Performant, and Fully Managed NoSQL Database Service](https://www.usenix.org/system/files/atc22-elhemali.pdf)
- [Dynamo paper](https://www.allthingsdistributed.com/files/amazon-dynamo-soho2007.pdf)
