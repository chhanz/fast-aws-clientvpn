# AWS Client VPN 자동화 도구

English version: [README.en.md](README.en.md)

AWS Client VPN을 명령 한 줄로 만들고 지우는 도구입니다. 인증서 발급부터 엔드포인트
배포, 접속용 설정 파일(.ovpn) 생성까지 한 번에 처리합니다.

- 인증서 "생성"은 셸 스크립트(`mgt-clientvpn.sh`)가 담당합니다.
- AWS 자원의 "상태"는 CloudFormation 템플릿(`clientvpn.yaml`)이 담당합니다.

인증은 상호 인증(서버/클라이언트가 같은 CA로 서명된 X.509 인증서) 방식을 사용합니다.

## 구성 파일

| 파일 | 설명 |
|------|------|
| `mgt-clientvpn.sh` | 통합 관리 스크립트 (단일 진입점) |
| `clientvpn.yaml`   | CloudFormation 템플릿 (VPN 인프라 선언) |
| `clientvpn.conf`   | `configure` 가 생성하는 설정 파일 (직접 만들지 않아도 됩니다) |

## 전제 조건

- 실행 호스트: Amazon Linux 2023 (또는 동급 리눅스)
- AWS CLI v2 설치 및 자격 증명 구성 (`aws configure` 또는 EC2 인스턴스 역할)
- `git` 설치 (인증서 생성 시 easy-rsa를 내려받습니다)
- 사용 계정에 필요한 권한: ACM, EC2(Client VPN), CloudFormation
- 대상 VPC와 서브넷이 이미 존재해야 합니다.

## 사용 순서

권장 흐름은 `configure` -> `deploy` -> `status` -> `gen` -> `destroy` 입니다.

### 1. configure - 환경값 입력

```bash
./mgt-clientvpn.sh configure
```

대화형으로 다음 값을 입력받아 `clientvpn.conf` 에 저장합니다.

| 항목 | 기본값 | 설명 |
|------|--------|------|
| Region | `ap-northeast-2` | 배포할 리전 |
| VPC ID | (필수) | `vpc-` 로 시작 |
| Subnet ID | (필수) | `subnet-` 로 시작 |
| Client CIDR | `10.100.0.0/22` | VPN 접속자에게 줄 IP 대역 (/12 ~ /22) |
| 사내망 CIDR | `172.31.0.0/16` | VPN으로 접근을 허용할 내부 대역 |
| Split Tunnel | `true` | true면 사내망 트래픽만 VPN으로 보냅니다 |
| DNS Servers | `169.254.169.253` | VPN 클라이언트에 푸시할 DNS. 기본값은 내부·외부 도메인 모두 해석 (비우면 클라이언트 기본 DNS 유지) |

입력값은 두 단계로 검증합니다.

- 형식 검증(항상): VPC/Subnet ID 접두사, Client CIDR 마스크 범위(/12 ~ /22).
- 실시간 검증(권한이 있을 때): 서브넷이 실제로 그 VPC에 속하는지 확인합니다.
  권한이 없으면 검증을 건너뛰고 수동 확인 안내를 보여준 뒤 진행합니다(배포를 막지 않습니다).

### 2. deploy - 배포

```bash
./mgt-clientvpn.sh deploy                # Split Tunnel (기본)
./mgt-clientvpn.sh deploy --full-tunnel  # Full Tunnel (모든 트래픽을 VPN으로)
```

동작 순서:

1. ACM에서 태그 `Name=clientvpn-server` 인 인증서를 찾습니다.
2. 없으면 easy-rsa로 CA/서버/클라이언트 인증서를 생성하고 ACM에 import 합니다.
   (있으면 그대로 재사용합니다. 이 태그가 멱등성의 유일한 기준입니다.)
3. CloudFormation으로 VPN 엔드포인트를 배포합니다.
4. 접속용 `.ovpn` 파일을 생성합니다 (스크립트와 같은 디렉토리의 `clientvpn-certs/` 아래).

> Split Tunnel과 Full Tunnel
> - Split(기본): 사내망(`TargetCidr`) 트래픽만 VPN을 거치고, 나머지는 일반 인터넷 회선으로 갑니다.
> - Full: 모든 트래픽(`0.0.0.0/0`)을 VPN으로 보냅니다. Split 모드에서는 `0.0.0.0/0` 경로를
>   만들지 않습니다(연결이 끊길 수 있어 의도적으로 막아둡니다).
> - Full Tunnel로 배포하면 인터넷 트래픽을 위한 인가 규칙(`0.0.0.0/0` authorization rule)이 자동으로 추가됩니다(이게 없으면 인터넷이 차단됩니다).

### 3. status - 상태 확인

```bash
./mgt-clientvpn.sh status
```

스택 상태, 엔드포인트 상태, 연결된 서브넷, 인증서 ARN, 터널 모드를 보여줍니다.

> Client CIDR은 엔드포인트 생성 후 변경할 수 없습니다. 바꾸려면 `destroy` 후 다시 배포해야 합니다.

### 4. gen - 접속 설정 재생성

```bash
./mgt-clientvpn.sh gen
```

이미 배포된 엔드포인트의 `.ovpn` 파일을 다시 내려받아 생성합니다.

### 5. destroy - 삭제

```bash
./mgt-clientvpn.sh destroy
```

`yes` 를 입력해야 진행합니다. 스택을 먼저 삭제하고 완료를 기다린 뒤 인증서를 정리합니다.
(엔드포인트가 인증서를 참조하고 있어 순서를 지키지 않으면 인증서 삭제가 실패합니다.)

## 생성되는 파일 위치

- 설정 파일: 스크립트와 같은 디렉토리의 `clientvpn.conf`
- 인증서/키 및 `.ovpn`: 스크립트와 같은 디렉토리의 `clientvpn-certs/`
  - 개인 키 파일은 권한 `600` 으로 저장됩니다.

## 트러블슈팅

| 증상 | 원인 / 해결 |
|------|-------------|
| `먼저 ./mgt-clientvpn.sh configure 를 실행하세요` | 설정 파일이 없습니다. `configure` 부터 실행하세요. |
| configure에서 자동 검증을 건너뛴다는 안내 | AWS CLI 권한이 없습니다. 콘솔에서 서브넷의 VPC를 직접 확인한 뒤 진행하세요. |
| `서브넷이 입력 VPC에 속하지 않습니다` | Subnet ID 또는 VPC ID를 잘못 입력했습니다. 값을 확인하세요. |
| 스택 생성이 ConnectionLogOptions 관련으로 실패 | 템플릿에 이미 `Enabled: false` 가 명시돼 있습니다. AWS CLI/권한을 확인하세요. |
| 배포 후 인터넷이 안 됨 (Full Tunnel) | 인터넷 인가 규칙은 이 도구가 자동 추가합니다. 그래도 안 되면 연결 서브넷의 라우트 테이블에 `0.0.0.0/0 -> IGW`(퍼블릭 서브넷) 또는 `0.0.0.0/0 -> NAT GW`(프라이빗 서브넷) 경로가 있어야 합니다. 이 부분은 이 도구 범위 밖이라 사전에 직접 확인해야 합니다. |
| 배포 후 도메인 이름 해석이 안 됨 (Full Tunnel) | 기본 DNS(`169.254.169.253`, AWS Route 53 Resolver)가 클라이언트에 푸시되는지 status로 확인하세요. configure에서 비워두면 클라이언트 기본 DNS가 쓰여 Full Tunnel에서 해석이 막힐 수 있습니다. |
| 사내망에 접근이 안 됨 (Split Tunnel) | `TargetCidr` 가 실제 사내망 대역과 맞는지 확인하세요. |
| `.ovpn` 에 인증서가 안 들어감 | 인증서를 생성한 호스트에서 `deploy` 를 실행했는지 확인하세요. 키가 로컬에 있어야 삽입됩니다. |
| destroy 시 인증서 삭제 실패 | 엔드포인트가 아직 인증서를 참조 중입니다. 스택 삭제가 끝났는지 확인 후 다시 시도하세요. |

## 참고

- 인증서 생성에는 [OpenVPN/easy-rsa](https://github.com/OpenVPN/easy-rsa) 를 사용합니다.
- 클라이언트는 AWS VPN Client 또는 OpenVPN 호환 클라이언트에서 `.ovpn` 파일로 접속합니다.
