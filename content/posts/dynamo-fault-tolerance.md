---
title: "Dynamo는 죽은 노드를 기다리지 않는다"
url: "/backend/infrastructure/2026/02/16/dynamo-fault-tolerance/"
date: 2026-02-16 19:00:00 +0900
categories: [backend, infrastructure]
---

Dynamo의 목표는 "항상 쓰기 가능"에 가깝다. 노드 하나가 죽었다고 쓰기를 바로 실패시키지 않는다. 정해진 복제 노드가 응답하지 않으면 살아 있는 다른 노드에 임시로 써두고, 나중에 원래 자리로 돌려놓는다.

## 선호 목록과 quorum

각 키는 consistent hashing ring 위에서 N개의 노드에 복제된다. 이 N개 노드가 preference list다.

```text
key cart#123
preference list = [A, B, C]
N=3, W=2, R=2
```

`W=2`는 쓰기 성공에 2개 응답이 필요하다는 뜻이다. 전통적인 quorum은 A, B, C 중 2개가 응답해야 한다. A가 죽고 C도 느리면 쓰기가 실패한다.

## Sloppy quorum

Dynamo는 정해진 노드만 고집하지 않는다. preference list의 노드가 죽었으면 ring을 더 돌아 살아 있는 다음 노드에 대신 쓴다.

```text
preference list: [A, B, C]
A down

write target: [B, C, D]
```

D는 원래 복제 대상이 아니지만, 지금 쓰기를 성공시키기 위해 임시로 받는다. 이것이 sloppy quorum이다. 정확한 위치보다 가용성을 우선한다.

## Hinted handoff

임시로 받은 D는 이 데이터가 원래 A의 것이라는 hint를 함께 저장한다.

```text
D stores:
  value = ...
  hint  = original node A
```

A가 복구되면 D는 데이터를 A로 넘기고, 자기 임시 복사본을 지운다. 장애가 짧으면 hinted handoff만으로 원래 복제 배치가 회복된다.

## Anti-entropy

장애가 길거나, 임시 복사본을 가진 노드까지 문제가 생기면 레플리카 간 차이가 남을 수 있다. 이때는 anti-entropy가 필요하다. 노드들이 서로 가진 데이터를 비교하고 빠진 부분을 채운다.

Dynamo는 Merkle tree를 써서 전체 데이터를 전송하지 않고 차이를 찾는다.

```text
root hash 같음  -> 같은 데이터
root hash 다름  -> 하위 hash 비교
              -> 다른 범위만 내려가며 찾음
              -> 다른 key만 동기화
```

데이터 전체를 매번 비교하지 않고, 해시 트리의 다른 가지를 따라가며 필요한 범위만 복구한다.

## Gossip과 로컬 장애 감지

Dynamo는 중앙 coordinator 하나가 전체 멤버십을 통제하지 않는다. 노드들은 gossip으로 멤버십 정보를 주고받고, 시간이 지나면 같은 상태로 수렴한다.

장애 감지도 전역 합의를 기다리지 않는다. 어떤 노드가 내 요청에 응답하지 않으면 "내 관점에서 죽었다"고 보고 다른 노드로 우회한다. 목적은 완벽한 진실 판정이 아니라 현재 요청을 성공시키는 것이다.

## 정리

| 문제 | Dynamo의 선택 |
|---|---|
| preference node가 죽음 | sloppy quorum으로 다른 노드에 씀 |
| 임시 저장 복구 | hinted handoff |
| 레플리카 간 불일치 | Merkle tree 기반 anti-entropy |
| 멤버십 전파 | gossip |
| 장애 판정 | 글로벌 합의보다 로컬 관점 |

이것이 강한 일관성보다 가용성을 앞에 둔 설계의 핵심이다.

## 참고자료

- [Dynamo: Amazon's Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-soho2007.pdf)
