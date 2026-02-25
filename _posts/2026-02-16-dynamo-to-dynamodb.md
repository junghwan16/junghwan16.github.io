---
title: "Dynamo는 왜 DynamoDB가 되었나"
date: 2026-02-16 21:00:00 +0900
categories: [backend, infrastructure]
---

2007년 논문으로 공개된 Amazon의 내부 시스템 Dynamo는 2012년 AWS DynamoDB라는 완전관리형 서비스로 다시 등장했다. 이름만 비슷할 뿐 아키텍처는 상당 부분 달라졌다.

왜 Amazon은 잘 돌아가던 Dynamo를 그대로 서비스하지 않고, 새로운 시스템을 만들었을까? 공개된 자료들을 바탕으로 그 이유를 추적해 본다.

---

## 시작: 2004년 홀리데이 시즌 장애

Dynamo의 탄생 배경부터 보자. 2004년 연말 쇼핑 시즌, Amazon.com은 데이터베이스 트랜잭션 데드락으로 장애를 겪었다. 당시 Amazon은 Oracle Enterprise Edition을 클러스터링과 복제 구성으로 운영하고 있었고, Oracle 사의 전문가까지 동원한 상태였다. 그런데도 트래픽 급증을 감당하지 못했다.

장애 사후 분석(Correction of Error, COE) 과정에서 당시 20살 인턴이었던 Swaminathan Sivasubramanian이 질문을 던졌다.

> "왜 이 워크로드에 관계형 데이터베이스를 쓰고 있는 건가요? SQL 수준의 복잡성이나 트랜잭션 보장이 필요한 것도 아닌데."

실제로 Amazon 플랫폼 운영의 약 70%가 key-value 형태의 단순한 조회였다. 이 질문을 계기로 Amazon은 데이터 저장소 아키텍처를 근본적으로 재고했고, Dynamo가 탄생했다. Sivasubramanian은 이후 Dynamo 논문의 공저자가 되었으며, 현재 AWS VP로 재직 중이다.

---

## Dynamo는 성공했지만, 운영은 고통이었다

Dynamo는 장바구니, 세션 관리 등 Amazon의 핵심 서비스를 안정적으로 지탱했다. 기술적으로는 성공이었다. 하지만 Werner Vogels(Amazon CTO)는 이렇게 회고한다.

> "Dynamo는 팀들에게 필요한 신뢰성, 성능, 확장성을 제공했지만, 대규모 데이터베이스 시스템을 운영하는 복잡성을 줄여주지는 못했다."

Dynamo는 단일 테넌트 시스템이었다. 각 팀이 자체적으로 Dynamo 인스턴스를 설치, 설정, 운영해야 했다. 이것은 각 팀에게 분산 시스템 전문가 수준의 역량을 요구했다. N, R, W 파라미터 튜닝, 노드 장애 대응, 데이터센터 간 복제 관리 등을 모두 직접 해야 했다.

---

## 개발자들은 발로 투표했다

한편 AWS에서는 SimpleDB라는 관리형 NoSQL 서비스를 제공하고 있었다. 기능은 Dynamo에 한참 미치지 못했다. 도메인당 10GB 저장소 제한, 모든 속성을 인덱싱하는 바람에 데이터가 커지면 느려지는 구조적 한계가 있었다.

그런데도 Amazon 내부 엔지니어들이 Dynamo 대신 SimpleDB를 선택하는 일이 벌어졌다. Vogels는 이를 "개발자들이 발로 투표했다(voted with their feet)"고 표현했다.

> "Dynamo는 당시 세계 최고의 기술이었을 수 있다. 하지만 여전히 직접 운영해야 하는 소프트웨어였다."

개발자들은 세밀한 제어권보다 **운영하지 않아도 되는 단순함**을 선택한 것이다. 이것은 DynamoDB 탄생의 가장 직접적인 계기가 되었다.

---

## 외부 고객도 같은 것을 원했다

2007년 Dynamo 논문이 공개되자, 외부에서도 관심이 쏟아졌다. AWS 고객 자문 위원회(Customer Advisory Board)에서 SmugMug의 CEO Don MacAskill이 직접적으로 요청했다.

> "왜 Dynamo를 외부 서비스로 제공하지 않는가?"

다른 고객들도 같은 요구를 했다. 파티셔닝, 리파티셔닝, 클러스터 프로비저닝을 직접 관리하지 않으면서도 Dynamo의 확장성을 원했다.

---

## 충돌 해결이라는 이론과 현실의 괴리

Dynamo의 핵심 설계 중 하나는 **클라이언트 측 충돌 해결**이었다. 벡터 클럭으로 버전 충돌을 감지하고, 애플리케이션이 비즈니스 로직에 맞게 병합하는 구조다.

이론적으로는 우아했다. 장바구니라면 합집합, 설정이라면 최신 값 우선 등 서비스 특성에 맞는 최적의 해결이 가능하다.

하지만 현실에서 대부분의 개발자는 충돌 해결 로직을 제대로 구현하지 않았다. 논문 자체에서도 "일부 애플리케이션 개발자는 자체 충돌 해결 메커니즘을 작성하고 싶어하지 않을 수 있으며, 이 경우 데이터 저장소에 위임하여 '최종 쓰기 승리' 같은 단순한 정책을 선택하게 된다"고 인정하고 있다.

Dynamo에서 영감을 받은 후속 시스템들(Cassandra, Riak 등)도 대부분 벡터 클럭 대신 최종 쓰기 승리(Last Write Wins)를 기본 정책으로 채택했다. 업계 전체가 같은 결론에 도달한 셈이다.

DynamoDB는 이 현실을 받아들여 서버 측 최종 쓰기 승리를 기본으로 채택하고, 대신 강한 일관성 읽기(Strongly Consistent Read) 옵션을 제공하는 방향으로 전환했다.

---

## 아키텍처도 크게 바뀌었다

DynamoDB는 이름만 이어받은 것이 아니라, 아키텍처 자체를 상당 부분 새로 설계했다. Marc Brooker(AWS 엔지니어)는 "DynamoDB는 이전 Dynamo 시스템의 이름 대부분을 공유하지만, 아키텍처는 거의 공유하지 않는다"고 평가했다.

주요 변경점:

| 항목 | Dynamo | DynamoDB |
|---|---|---|
| 복제 방식 | Quorum 기반 (N, R, W) | Multi-Paxos 합의 |
| 충돌 해결 | 클라이언트 측 벡터 클럭 | 서버 측 최종 쓰기 승리 |
| 일관성 | 최종 일관성만 | 최종 일관성 + 강한 일관성 읽기 |
| 운영 모델 | 팀별 자체 운영 | AWS 완전 관리 |
| 멤버십 | 가십 프로토콜 (탈중앙) | AWS 중앙 관리 |

특히 복제 방식이 Quorum에서 Multi-Paxos로 바뀐 것은 큰 변화다. 리더 노드만 쓰기와 강한 일관성 읽기를 처리하고, 팔로워 노드는 최종 일관성 읽기를 담당하는 구조로 전환했다. Dynamo의 "모든 노드가 동등"하다는 탈중앙 원칙을 포기한 대신, 운영 단순성과 일관성 보장을 얻었다.

---

## 정리: 왜 DynamoDB가 되었나

Dynamo가 DynamoDB로 변한 이유를 정리하면 다음과 같다.

| 요인 | 설명 |
|---|---|
| 운영 복잡성 | 각 팀이 직접 운영해야 하는 부담이 채택을 가로막았다 |
| 개발자 선호 | 기능이 부족해도 관리형 서비스(SimpleDB)를 선택했다 |
| 충돌 해결의 현실 | 클라이언트 측 해결 로직을 제대로 구현하는 팀이 드물었다 |
| 외부 수요 | AWS 고객들이 Dynamo를 서비스로 원했다 |
| AWS 비즈니스 | 관리형 서비스가 AWS의 핵심 사업 모델이다 |

결국 Dynamo의 기술적 우수성만으로는 부족했다. 개발자가 실제로 사용할 수 있는 형태, 즉 운영 부담 없이 테이블만 만들면 되는 형태가 필요했다. DynamoDB는 Dynamo의 설계 철학 중 검증된 부분(확장성, 예측 가능한 저지연)을 가져오되, 현실에서 작동하지 않은 부분(클라이언트 충돌 해결, 탈중앙 운영)은 과감히 버린 결과물이다.

---

## 참고자료

- [Amazon DynamoDB — a Fast and Scalable NoSQL Database Service Designed for Internet Scale Applications (Werner Vogels, 2012)](https://www.allthingsdistributed.com/2012/01/amazon-dynamodb.html) — DynamoDB 출시 발표, Dynamo/SimpleDB의 한계 회고
- [A Decade of Dynamo (Werner Vogels, 2017)](https://www.allthingsdistributed.com/2017/10/a-decade-of-dynamo.html) — Dynamo 10주년 회고, 2004년 장애와 NoSQL 운동 촉발
- [Amazon's DynamoDB — 10 years later (Amazon Science, 2022)](https://www.amazon.science/latest-news/amazons-dynamodb-10-years-later) — Sivasubramanian 인턴 일화, Dynamo에서 DynamoDB까지의 전체 여정
- [Happy 10th Birthday, DynamoDB! (AWS Blog, 2022)](https://aws.amazon.com/blogs/aws/happy-birthday-dynamodb/) — DynamoDB 10주년, 2004년 Oracle 장애 배경
- [Amazon DynamoDB: A Scalable, Predictably Performant, and Fully Managed NoSQL Database Service (USENIX ATC'22)](https://www.usenix.org/system/files/atc22-elhemali.pdf) — DynamoDB 아키텍처 논문, 운영 경험
- [The DynamoDB Paper (Marc Brooker, 2022)](https://brooker.co.za/blog/2022/07/12/dynamodb.html) — "이름 대부분을 공유하지만 아키텍처는 거의 공유하지 않는다"
- [Key Takeaways from the DynamoDB Paper (Alex DeBrie)](https://www.alexdebrie.com/posts/dynamodb-paper/) — SimpleDB 대비 Dynamo 채택률 분석
- [The Dynamo Paper (DynamoDB Guide)](https://www.dynamodbguide.com/the-dynamo-paper/) — Dynamo 논문 해설
- [Dynamo: Amazon's Highly Available Key-value Store (원문, 2007)](https://www.allthingsdistributed.com/files/amazon-dynamo-soho2007.pdf) — 원 논문
