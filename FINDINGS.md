# FINDINGS: bench LLM agent trên RCAEval

Nhật ký các phát hiện khi bench agent LLM. Mỗi mục ghi: hiện tượng, nguyên nhân, cách sửa,
version thay đổi, kết quả trước/sau, và file kết quả để tra lại.

## Bảng version

Mỗi prediction (và dòng `meta` đầu mỗi trajectory) ghi cả hai version, nên luôn biết một
kết quả được chạy với cấu hình nào.

| Thành phần | Version | Nội dung | Ở đâu |
|---|---|---|---|
| Prompt | `1` | Gọi `rank_anomalies` rồi xác nhận; yêu cầu "be efficient". | `RCAEval/agent/prompt.py` |
| Prompt | `2` (mặc định) | Không tin một ranking duy nhất; kiểm tra 3-5 nghi phạm bằng bằng chứng riêng của từng service. | `RCAEval/agent/prompt.py` |
| Prompt | `nobaro` | Như v2 nhưng không có `rank_anomalies`; agent tự tìm thay đổi từ telemetry thô. | `script/run_agent_nobaro.py` |
| Toolkit | `1` | `rank_anomalies(metrics)` = BARO y hệt `RCAEval.e2e.baro`. **Có lỗi F1.** | `RCAEval/agent/toolkit.py` |
| Toolkit | `2` (mặc định) | Sửa F1: giữ series phẳng trước inject, không chấm theo đơn vị thô. Logs/traces giữ nguyên như v1. | `RCAEval/agent/toolkit.py` (`robust_score`) |

Chọn version khi chạy: `rcaeval-agent run --prompt-version 2 --toolkit-version 2 ...`
(`run-cli` và `mcp` nhận cùng tuỳ chọn). Baseline BARO (`RCAEval.e2e.baro`, `main.py`)
**không đổi**, để còn so sánh được với paper.

## Quy ước tên file kết quả

`script/bench_llm.sh` với `ARM`, `TOOLKIT_VERSION`, `REP`:

```
results/{preds,percase,summary,report}_<model>_<arm>_tk<version>_<subset>_r<rep>.*
results/log_<arm>_tk<version>_<subset>_r<rep>.txt
```

Các file **trước khi có toolkit version** (không có `_tk`) đều là toolkit v1:

| File cũ | Tương đương |
|---|---|
| `results/*_openai_gpt-6-luna_all90.*` | `baro_tk1_all90_r1` |
| `results/*_openai_gpt-6-luna_nobaro_all90.*` | `nobaro_all90_r1` (arm này không dùng `rank_anomalies`, nên v1 hay v2 như nhau) |
| `results/*_openai_gpt-6-luna_pilot30.*`, `*_nobaro_pilot30.*` | 30 case đầu của hai file trên (all90 tái dùng pilot30, không phải lần chạy độc lập) |
| `results/*_baro_all90.*` | BARO đứng riêng (baseline, không LLM) |

So sánh các lần chạy: `script/compare_runs.py` (bảng AC@1 theo fault, chi phí, McNemar paired).

---

## F1. LLM không có BARO tốt hơn LLM có BARO (2026-11-11)

**Setup:** RE2-OB, 90 case (6 loại fault × 15), `openai/gpt-6-luna` (tier rẻ), prompt v2 /
nobaro, temperature 0, max 30 steps.

### Hiện tượng

| Run | service AC@1 | indicator AC@1 | indicator Avg@5 | $/case | tool calls/case |
|---|---|---|---|---|---|
| LLM + BARO (toolkit v1) | 0.97 | 0.56 | 0.74 | 0.0029 | 30.4 |
| LLM không BARO | 1.00 | 0.70 | 0.86 | 0.0042 | 41.9 |
| BARO đứng riêng | 0.14 | 0.09 | 0.39 | - | - |

Paired: indicator AC@1 lệch 6 vs 19 case (McNemar p = 0.015). Service AC@1 đã chạm trần
(lệch 0 vs 3, p = 0.25), nên trên RE2-OB metric này không phân biệt được các arm.

Toàn bộ chênh lệch dồn vào hai loại fault:

| fault | indicator AC@1 với BARO v1 | không BARO | metric đúng `<root>_<indicator>` có trong output BARO v1 |
|---|---|---|---|
| disk | 5/15 | 14/15 | **0/15** |
| socket | 0/15 | 2/15 | **0/15** |
| 4 loại còn lại (60 case) | 45/60 | 47/60 | 57/60 |

Bỏ disk và socket ra thì hai arm ngang nhau (lệch 6 vs 8 case, p ≈ 0.8).

### Nguyên nhân

1. **BARO bỏ series phẳng trước inject.** `RCAEval/e2e/baro.py` gọi `preprocess()` (bên trong
   có `drop_constant`) riêng cho nửa normal và nửa anomalous, rồi chỉ giữ các cột có ở cả
   hai nửa. Một metric hằng số trước inject bị xoá dù sau inject nó nhảy mạnh, mà đó lại là
   tín hiệu rõ nhất. Ví dụ:
   - `re2-ob-0024 productcatalogservice_diskio`: trước = 0, sau ≈ 9.4e9, bị loại.
   - `re2-ob-0001 currencyservice_socket`: trước = 4, sau = 17-19, bị loại.

   Tình huống này xảy ra ở **mọi** case disk và socket của RE2-OB.
2. **IQR = 0 làm score tính theo đơn vị thô.** Với series bursty mà phần lớn bằng 0 (IQR = 0),
   `RobustScaler` dùng scale = 1, nên score tính bằng byte. `redis_diskio` (nhiễu, lần nào
   cũng nhảy) vì thế đứng **top-1 trong 78/90 case**.
3. **LLM tier rẻ bị anchoring theo ranking.** Với BARO, agent chỉ mở `get_metric(<root>_diskio)`
   ở 5/15 case disk (không BARO: 14/15). Nó còn tự gạt diskio đi vì thấy `redis_diskio` nhiễu
   ("Redis disk I/O is bursty… does not track the incident", re2-ob-0024).

Vậy kết luận đúng là: **tool BARO v1 che mất tín hiệu disk/socket và đẩy nhiễu lên đầu**.
Không phải "LLM không cần anomaly ranking".

### Cách sửa: toolkit v2

`robust_score(normal, anomal, window)` trong `RCAEval/agent/toolkit.py`:

- Bỏ series hằng số trên **toàn cửa sổ** (không theo từng nửa); chuyển mem sang MB như BARO.
- Score = `max(anomal - median(normal)) / scale`, trong đó `scale` lần lượt là: IQR(normal);
  nếu ≈ 0 thì std(normal); nếu vẫn ≈ 0 (phẳng trước inject) thì 1% range của series trên
  cửa sổ. Một bước nhảy từ nền phẳng vì thế có score ≈ 100 bất kể đơn vị.
- "≈ 0" nghĩa là ≤ 1e-9 × max|series|: IQR của một hằng số có thể ra ~1e-18 do sai số float.
- Series có IQR > 0 được chấm **giống hệt** BARO.
- Chỉ thay đổi `rank_anomalies(metrics)`. Logs/traces giữ nguyên v1 (xem "Còn mở").

Kiểm tra offline (không LLM) trên 90 case: thứ hạng của `<root>_<indicator>` trong output của tool.

| | ind@1 | ind@5 | ind@20 (top_k mặc định) | service top-1 | service top-3 |
|---|---|---|---|---|---|
| toolkit v1 | 8 | 52 | 57 | 13 | 79 |
| toolkit v2 | 33 | 85 | **90** | 77 | 87 |

Độ nhạy của ngưỡng nền phẳng (được chọn trên chính 90 case này, cần lưu ý; sweep chạy trước
khi thêm tolerance float nên số tuyệt đối hơi khác bảng trên): với fallback std,
1% cho ind@5 = 84 và 5% cho ind@5 = 63 (disk tụt xuống top-5 chỉ còn 3/15, vì socket nhiễu
của các service khác cũng ≈ 1/fraction). Ở **mọi** giá trị đã thử (0.5%, 1%, 5%),
ind@20 = 90/90, tức metric đúng luôn nằm trong phần agent nhìn thấy.

Test: `tests/test_agent_toolkit.py` (`test_robust_score_does_not_score_in_raw_units`,
`test_version_2_keeps_series_flat_before_the_inject_time`). Test so khớp với BARO tham chiếu
giờ chạy với `version="1"`.

### Kết quả sau khi sửa (2026-11-11)

Mỗi cấu hình chạy 2 lần trên all90 (gpt-6-luna, prompt v2/nobaro, temperature 0).

| Run | service AC@1 | ind AC@1 | ind AC@3 | ind Avg@5 | cpu | mem | disk | socket | delay | loss | $/case | calls |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baro tk1 r1 | 87 | 50 | 71 | 0.742 | 12 | 12 | 5 | 0 | 14 | 7 | 0.0029 | 30.4 |
| baro tk1 r2 | 89 | 53 | 71 | 0.738 | 12 | 13 | 3 | 0 | 15 | 10 | 0.0028 | 30.2 |
| baro tk2 r1 | 89 | 57 | 81 | 0.847 | 11 | 13 | 6 | 1 | 13 | 13 | 0.0026 | 28.9 |
| baro tk2 r2 | 89 | 57 | 78 | 0.836 | 12 | 11 | 7 | 1 | 14 | 12 | 0.0026 | 28.7 |
| nobaro r1 | 90 | 63 | 81 | 0.858 | 14 | 8 | 14 | 2 | 15 | 10 | 0.0042 | 41.9 |
| nobaro r2 | 90 | 60 | 81 | 0.847 | 12 | 11 | 11 | 1 | 14 | 11 | 0.0041 | 40.8 |

(Cột cpu…loss là indicator AC@1, mỗi loại /15.)

**Nhiễu giữa các lần chạy là lớn.** Dù temperature = 0, hai lần chạy cùng cấu hình vẫn
lệch nhau ở 11-15/90 case về indicator AC@1 (tk1: 6 vs 9; tk2: 7 vs 7; nobaro: 7 vs 4). Vì
vậy so sánh hai lần chạy đơn lẻ không đủ tin cậy; dưới đây là so sánh gộp các rep (điểm mỗi
case = trung bình 2 rep; sign-flip permutation test paired theo case; bootstrap 95% CI):

| So sánh | ind AC@1 (B − A) | p | ind Avg@5 (B − A) | p |
|---|---|---|---|---|
| tk1 → tk2 (tác dụng của bản sửa) | +0.061 [−0.011, +0.139] | 0.16 | **+0.101 [+0.041, +0.167]** | **0.002** |
| tk2 → nobaro | +0.050 [−0.044, +0.144] | 0.36 | +0.011 [−0.043, +0.068] | 0.73 |
| tk1 → nobaro (F1 ban đầu, có lặp) | **+0.111 [+0.028, +0.200]** | **0.018** | **+0.112 [+0.048, +0.181]** | **0.001** |

**Kết luận:**

1. F1 được xác nhận sau khi có lặp: với toolkit v1, arm không-BARO tốt hơn rõ ràng.
2. Toolkit v2 cải thiện có ý nghĩa thống kê ở indicator Avg@5 (+0.10, p = 0.002). Thứ hạng
   của indicator đúng tăng lên (AC@3: 71 → 78-81). AC@1 cũng tăng (+0.06) nhưng chưa đủ
   ý nghĩa với 90 case × 2 rep.
3. Sau khi sửa, **LLM + BARO và LLM không BARO không còn khác nhau có ý nghĩa** (Avg@5 chênh
   0.01, p = 0.73), trong khi arm có BARO **rẻ hơn ~37%** ($0.0026 so với $0.0041/case) và ít
   tool call hơn (29 so với 41).
4. Phần chênh còn lại tập trung ở fault **disk** (gộp: 6.5 so với 12.5 /15). Agent giờ đã thấy
   và mở `<root>_diskio` (13/15 case ở tk2 r2, so với 5/15 ở tk1), nhưng vẫn xếp `mem` lên
   trước. Lý do: trong RE2-OB, fault disk cũng đẩy memory lên tới trần (vd. 44 → 268 MB, có lẽ
   do page cache). `mem` có z-score cỡ hàng nghìn, còn `diskio` tăng từ đúng 0 nên theo thiết
   kế chỉ ≈ 100. Model bám theo thứ tự này (anchoring ở mức thứ hạng trong top-5). Arm
   không-BARO không có thứ tự nào để bám.
5. Độ lớn mẫu: CI của hiệu ứng AC@1 rộng khoảng ±0.09, nên với 90 case × 2 rep, các khác
   biệt AC@1 nhỏ hơn ~0.09 là không phát hiện được. Muốn kết luận chắc hơn, cần thêm rep
   (rẻ: ~$0.25/run) hoặc thêm dataset (RE2-TT).

So sánh lại:

```
R=results; M=openai_gpt-6-luna
.venv/bin/python script/compare_runs.py \
  baro_tk1_r1=$R/percase_${M}_all90.jsonl baro_tk1_r2=$R/percase_${M}_baro_tk1_all90_r2.jsonl \
  baro_tk2_r1=$R/percase_${M}_baro_tk2_all90_r1.jsonl baro_tk2_r2=$R/percase_${M}_baro_tk2_all90_r2.jsonl \
  nobaro_r1=$R/percase_${M}_nobaro_all90.jsonl nobaro_r2=$R/percase_${M}_nobaro_tk2_all90_r2.jsonl \
  --groups tk1=baro_tk1_r1,baro_tk1_r2 tk2=baro_tk2_r1,baro_tk2_r2 nobaro=nobaro_r1,nobaro_r2 \
  --group-pairs tk1:tk2 tk2:nobaro tk1:nobaro
```

### Còn mở

- **Logs/traces cũng có vấn đề IQR = 0 → đơn vị thô**, nhưng áp dụng `robust_score` cho
  trace_latency làm kết quả **tệ hơn** offline (service top-1: 29 → 19). Lý do: series 15 s
  bị lượng tử hoá, nhiều series phẳng trước inject, nên tất cả cùng ≈ 100 và mất thông tin độ
  lớn, mà với latency thì độ tăng ms thô lại là tín hiệu tốt. Logs thì tốt hơn (2 → 8). Chưa
  đưa vào v2 để ablation sạch; cần một cách tie-break theo độ lớn trước khi làm v3.
- Nhiều series phẳng trước inject cùng ra ≈ 100 (vd. socket của nhiều service nhảy 3 → 4)
  và hoà điểm với root cause. Có thể tie-break theo độ thay đổi tương đối.
- **Ứng viên v3:** cho series tăng từ nền phẳng một score cao hơn, để `<root>_diskio` không
  đứng sau `mem` trong các fault disk (xem kết luận 4). Phải làm sao không đẩy nhiễu socket
  (3 → 4) lên cùng; và vì các tham số đang được chọn trên chính RE2-OB, nên kiểm chứng trên
  RE2-TT trước khi đổi mặc định.
- Chỉ bench RE2-OB; service-level đã chạm trần. Cần RE2-TT để kết luận tổng quát.

---

## Ghi chú vận hành

- **Lỗi tạm thời của provider làm dừng cả batch (2026-11-11).** Khi chạy 4 lượt song song
  (16 request đồng thời), 3/4 lượt chết vì `Connection reset by peer` và Cloudflare `520`
  từ `api.openai.com`. Một exception trong worker làm dừng cả `run_batch`. Những case đã xong
  vẫn được ghi; chạy lại cùng lệnh sẽ bỏ qua chúng (case dở dang chạy lại từ đầu).
  **Sửa:** `react.litellm_completion` truyền `num_retries=4` (`COMPLETION_RETRIES`). Không
  đổi version vì không ảnh hưởng hành vi của agent.
- **LiteLLM 1.109 gọi `/v1/responses` cho `openai/gpt-6-luna`** (thấy trong URL của lỗi), dù
  client dùng `litellm.completion` kiểu chat. Vậy "chat completions" ở đây thực chất đi qua
  Responses API bằng lớp bridge của LiteLLM. Client không truyền `reasoning_effort`, nên mức
  thinking là mặc định của model hoặc provider; nên ghim tường minh nếu sau này so sánh
  theo trục reasoning.
