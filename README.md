# dx-m1-device-tools

통합제어기(CM5 기반)에 장착한 DEEPX DX-M1 NPU 모듈(DX-M1BNM5604)의 상태 점검과 성능 측정 스크립트입니다. 통합제어기에서 실행합니다.

| 파일 | 용도 | DX-M1 개발 입문서 |
|---|---|---|
| `dx-selftest.sh` | PCIe, 드라이버, 런타임·서비스, 펌웨어·NPU를 점검하고 PASS·WARN·FAIL로 판정 | 3장 |
| `dx-bench.sh` | 모델별 지연·FPS·자원 사용률 측정(`-u`: 모델의 CPU 작업 포함), 장시간 안정성 시험 | 10장 |

## 사용법

```sh
git clone https://github.com/Gyurinet/dx-m1-device-tools.git ~/dx-m1-device-tools
cd ~/dx-m1-device-tools
chmod +x dx-selftest.sh dx-bench.sh

./dx-selftest.sh                                   # 상태 점검
./dx-selftest.sh -m <모델>.dxnn -l 100             # 추론 시험 포함
./dx-selftest.sh -o selftest-$(date +%Y%m%d).log   # 결과를 파일로도 저장

./dx-bench.sh -u -t 30 -o ~/bench/gen3 <모델1>.dxnn <모델2>.dxnn   # 모델별 측정(CPU 작업 포함)
./dx-bench.sh -S 60 -o ~/bench/stability <모델>.dxnn             # 60분 안정성 시험
```

`dx-selftest.sh`는 FAIL이 없으면 종료 코드 0, 하나라도 있으면 1을 돌려줍니다.

## 확인한 환경

- 통합제어기: Raspberry Pi Compute Module 5, Debian 13(trixie), 커널 6.18.50+rpt-rpi-2712
- DEEPX: `dxrt-driver-dkms` 2.6.0-2, `libdxrt-bin`(DX-RT) 3.4.2, 펌웨어 v2.7.4, PCIe Gen3 x1
- 필요한 명령: `dxrt-cli`, `dxrun`(DX-RT에 포함), `lspci`, `vcgencmd`

## 라이선스

규리넷 주식회사의 독점 라이선스입니다. 제품을 공급받은 고객은 제품의 개발·시험·운영 목적으로 사용·수정할 수 있으며, 서면 허가 없이 제3자에게 배포할 수 없습니다. 자세한 조건은 `LICENSE`를 참고합니다.
