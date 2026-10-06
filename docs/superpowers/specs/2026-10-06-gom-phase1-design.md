# Gom – Đợt 1: Hàng đợi + tải HTTP đa luồng + bắt tải từ Chrome

Ngày: 2026-10-06 · Trạng thái: chờ duyệt

## 1. Mục tiêu

App macOS tải file cho người dùng cá nhân (chưa phát hành). Lộ trình 3 đợt:

1. **Đợt 1 (spec này):** hàng đợi + tải HTTP đa luồng, tạm dừng/tải tiếp + extension Chrome tự chặn lượt tải.
2. Đợt 2: tải video qua `yt-dlp`, dùng chung hàng đợi.
3. Đợt 3: đặt lịch tải, tự xếp file theo loại.

**Hoàn thành đợt 1 khi:** toàn bộ test Swift pass; checklist thử tay của extension (mục 7) đạt; một file ISO khoảng 1GB tải qua Gom có checksum trùng với bản Chrome tải.

**Ngoài phạm vi đợt 1:** yt-dlp, đặt lịch, xếp file theo loại, icon menu bar, tự chia lại đoạn, giới hạn băng thông, chỉnh số đoạn trong UI, Safari/Firefox, ký code/notarize.

## 2. Công nghệ

- Swift 6, SwiftUI, deployment target macOS 27, Xcode 27.
- Chỉ dùng Foundation, SwiftUI, Network.framework. Không có dependency ngoài.
- Extension Chrome Manifest V3 (chạy được trên Chrome/Arc/Brave/Edge), cài bằng "Load unpacked".

Cấu trúc repo:

```
Gom/          dự án Xcode (app + test target)
extension/    manifest.json, background.js, options.html, options.js, README.md
docs/
```

## 3. Kiến trúc

```
Extension ──POST 127.0.0.1:47615/add──▶ BridgeServer ─┐
                                                      ├─▶ DownloadQueue ─▶ DownloadTask (mỗi file 1 task)
Ô dán link / kéo-thả ─────────────────────────────────┘          │
                                                                 ▼
                                                    UI SwiftUI (@Observable)
```

| Thành phần | Trách nhiệm | Phụ thuộc |
|---|---|---|
| `DownloadTask` | Tải 1 URL ra 1 file: probe, chia đoạn, tạm dừng/tải tiếp, thử lại | URLSession, FileHandle |
| `DownloadQueue` | Danh sách lượt tải, giới hạn chạy song song, lưu/khôi phục | DownloadTask, Codable |
| `BridgeServer` | Nhận request từ extension, xác thực rồi đẩy vào queue | Network.framework |
| UI | Danh sách lượt tải, ô dán link, cài đặt | DownloadQueue |
| Extension | Chặn lượt tải của Chrome, gửi sang Gom; Gom lỗi thì trả lại cho Chrome | chrome.downloads, chrome.cookies |

## 4. Công cụ tải (`DownloadTask`)

**Probe.** Gửi `GET` với `Range: bytes=0-0`, kèm cookie/Referer/User-Agent nếu có.
- `206` có `Content-Range: bytes 0-0/<total>` nghĩa là server hỗ trợ Range, biết luôn kích thước.
- `200` hoặc không biết kích thước thì tải 1 luồng, không tải tiếp được. Tạm dừng nghĩa là dừng hẳn, lần sau tải lại từ đầu, UI ghi rõ điều này.
- Tên file lấy theo thứ tự: tên extension gửi → `Content-Disposition` → phần cuối URL.
- Lưu `ETag` (nếu không có thì `Last-Modified`) để kiểm tra khi tải tiếp.

**Chia đoạn.**
- Mặc định 8 đoạn (hằng số). File dưới 2MB dùng 1 đoạn. Các đoạn phủ đúng `[0, total)`, không chồng, không hở.
- Ghi vào file tạm `<tên>.gomdownload` trong thư mục đích. Mỗi đoạn có `FileHandle` riêng, ghi theo offset của mình.
- Mỗi đoạn là 1 request `Range: bytes=<start+done>-<end>`. Nhận dữ liệu theo khối qua `URLSessionDataDelegate`, không dùng `URLSession.bytes` vì nó trả từng byte một, chậm.
- Xong thì đổi tên file tạm thành tên thật. Trùng tên thì thêm ` (1)`, ` (2)`…

**Tạm dừng / tải tiếp.**
- Tiến độ từng đoạn `{start, end, done}` được lưu khoảng 2 giây một lần và ngay khi tạm dừng.
- Khi tải tiếp, mỗi đoạn gửi lại request từ chỗ đã dừng kèm `If-Range: <ETag|Last-Modified>`. Server trả `200` thay vì `206` nghĩa là file đã đổi: xóa file tạm, tải lại từ đầu.
- Khi thoát app, các lượt đang tải lưu thành `paused`. Mở lại app thì tự tải tiếp.

**Lỗi.**
- Mỗi đoạn thử lại tối đa 5 lần, chờ 1s, 2s, 4s, 8s, 16s. Hết lượt thử thì cả lượt tải thành `failed(lý do)`, có nút "Thử lại".
- `401`/`403` báo `failed` ngay, không thử lại.

## 5. Hàng đợi, lưu trạng thái, UI

**`DownloadQueue`** (`@Observable`, `@MainActor`, 1 instance).
- Trạng thái: `queued | downloading | paused | completed | failed(String)`.
- Tối đa 3 lượt `downloading` cùng lúc. Khi có slot trống thì chạy lượt `queued` cũ nhất.
- Thao tác: thêm, tạm dừng, tiếp, thử lại, xóa khỏi danh sách, xóa kèm file.
- Thêm URL đã có trong hàng đợi mà chưa `completed` thì bỏ qua và làm nổi bật lượt cũ.

**Lưu trạng thái.** File `~/Library/Application Support/Gom/downloads.json`, dùng `Codable`, ghi atomic.
- Mỗi bản ghi gồm: `id, url, headers, filename, directory, totalBytes, etag, segments, state, addedAt`.
- Cookie lưu dạng chữ thường. Chấp nhận được vì máy chỉ mình người dùng dùng; nếu phát hành thì chuyển sang Keychain.
- Lượt tải chuyển sang `completed` thì xóa `headers` khỏi bản ghi.

**UI.**
- Một cửa sổ: ô dán link nhiều dòng + nút Thêm, danh sách lượt tải (tên, thanh tiến độ, %, tốc độ, nút ⏸/▶/↻/✕/📂), kéo-thả URL vào danh sách.
- Bấm đúp lượt đã xong để mở file; 📂 mở Finder và chọn sẵn file.
- Thông báo của macOS khi tải xong.
- Cài đặt: thư mục lưu (mặc định `~/Downloads`), port (mặc định 47615), token (có nút copy).

## 6. BridgeServer và extension

**BridgeServer.**
- `NWListener` chỉ nghe trên `127.0.0.1`. Bộ đọc HTTP/1.1 tối giản: dòng đầu, header, body theo `Content-Length`.
- `GET /ping` trả `{"ok":true,"app":"Gom"}`.
- `POST /add` nhận `{url, filename?, referrer?, cookies?, userAgent?}` và trả `{"ok":true}`.
- Xác thực: `Origin` phải bắt đầu bằng `chrome-extension://` **và** `X-Gom-Token` phải khớp. Sai thì trả `401`.
  - Token: 32 byte ngẫu nhiên dạng hex, sinh ở lần chạy đầu, lưu trong `UserDefaults`.
- Không trả header CORS. `OPTIONS` trả `403`, nên trang web không gửi được header tự đặt.
- Request quá 1MB hoặc JSON sai định dạng trả `400`.

**Extension.**
- Quyền: `downloads`, `cookies`, `storage`; `host_permissions: ["<all_urls>"]`.
- Xử lý `downloads.onCreated(item)`:
  1. Bỏ qua (để Chrome tự tải) nếu extension đang tắt, URL là `blob:`/`data:`, hoặc kích thước đã biết nhỏ hơn ngưỡng (mặc định 5MB).
  2. `chrome.downloads.pause(item.id)`.
  3. Lấy cookie bằng `chrome.cookies.getAll({url})` và ghép thành `name=value; …`. Thêm `item.referrer` và `navigator.userAgent`.
  4. Gửi `POST /add`, timeout 2s (dùng `AbortController`).
  5. Thành công thì `cancel` rồi `erase`. Lỗi hoặc timeout thì `resume`.
- Trang cài đặt: công tắc bật/tắt, port, token, ngưỡng MB, nút "Kiểm tra kết nối" (gọi `/ping`).

**Giới hạn đã biết.**
- Lượt tải tạo từ form POST sẽ hỏng vì Gom gửi lại bằng GET. Với các trang này, tạm tắt extension.
- Nếu Chrome bật "Hỏi nơi lưu trước khi tải" thì hộp thoại có thể hiện ra trước khi extension chặn. Khuyến nghị tắt tùy chọn này.
- File rất nhỏ có thể tải xong trước khi `pause` có tác dụng. Ngưỡng 5MB che được trường hợp này.

## 7. Kiểm thử

**Swift Testing.** Dùng một `URLProtocol` giả phục vụ `Data` trong bộ nhớ. Nó hỗ trợ `Range`/`If-Range` và cấu hình được để: lỗi N lần đầu, trả 403, đổi ETag.

- Chia đoạn: phủ đúng `[0,total)`; file dưới 2MB thì 1 đoạn.
- Probe: `206` thì chia đoạn, `200` thì 1 luồng.
- Tải đủ file: SHA256 khớp dữ liệu gốc.
- Tạm dừng ở khoảng 40% rồi tải tiếp: SHA256 khớp, request tải tiếp có `Range` bắt đầu đúng chỗ đã dừng.
- ETag đổi: tải lại từ đầu, SHA256 khớp dữ liệu mới.
- Lỗi 2 lần rồi thành công thì `completed`; `403` thì `failed` ngay.
- Queue: thêm 5 lượt thì chỉ 3 lượt chạy cùng lúc; URL trùng bị bỏ qua.
- Lưu trạng thái: ghi rồi đọc lại khớp; bản ghi `completed` không còn cookie.
- Bộ đọc HTTP: đọc đúng request hợp lệ; request quá 1MB bị từ chối.
- BridgeServer chạy thật trên port ngẫu nhiên ở `127.0.0.1`: thiếu token hoặc sai Origin trả 401; `OPTIONS` trả 403; request hợp lệ thì lượt tải vào queue.

**Checklist thử tay extension** (ghi trong `extension/README.md`):

1. Tải file ISO lớn → Gom nhận, lượt tải biến khỏi danh sách của Chrome.
2. Tắt Gom, tải file lớn → Chrome tự tải tiếp.
3. File 1MB → Chrome tự tải, Gom không can thiệp.
4. File cần đăng nhập (Google Drive) → Gom tải được nhờ cookie.
5. Token sai → "Kiểm tra kết nối" báo lỗi.
