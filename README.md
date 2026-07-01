# 🚀 Condere

**Condere** là một dự án mã nguồn mở nhỏ gọn và mạnh mẽ, được thiết kế nhằm đơn giản hóa quy trình thiết lập môi trường làm việc trên Linux. Công cụ này giúp bạn tự động hóa việc cài đặt các phần mềm cần thiết thông qua các chế độ cấu hình sẵn (profiles) phù hợp với từng nhu cầu cụ thể.

---

## 🛠️ Các chế độ cài đặt (Profiles)

Chúng tôi đã khảo sát và chọn lọc các phần mềm phổ biến nhất cho từng nhóm đối tượng. Bạn có thể linh hoạt lựa chọn chế độ phù hợp ngay khi khởi chạy công cụ:

| Chế độ | Đối tượng hướng đến | Mô tả |
| :--- | :--- | :--- |
| **`Common`** | Người dùng phổ thông | Các công cụ giải trí, trình duyệt, và tiện ích hệ thống cơ bản. |
| **`Developer`** | Lập trình viên | Trình biên dịch, Docker, Git, và các IDE/Text Editor phổ biến. |
| **`Data`** | Kỹ sư/Chuyên viên Dữ liệu | Công cụ quản trị cơ sở dữ liệu, Python, và các thư viện phân tích. |
| **`Officer`** | Nhân viên văn phòng | Bộ gõ tiếng Việt, ứng dụng văn phòng, và công cụ quản lý công việc. |
| **`Designer`** | Nhà thiết kế đồ họa | Các phần mềm chỉnh sửa ảnh, vector, và quản lý tài nguyên đồ họa. |

---

## 📋 Yêu cầu hệ thống

Trước khi bắt đầu, hãy đảm bảo hệ thống của bạn đáp ứng các điều kiện sau:
* Hệ điều hành: **Linux**
* Bản phân phối (Distro): **Ubuntu** hoặc các distro dựa trên Ubuntu (Linux Mint, Pop!_OS, Zorin OS...) có sử dụng trình quản lý gói **`apt`**.

---

## ⚡ Hướng dẫn sử dụng

Mở terminal lên và chạy chuỗi lệnh sau để bắt đầu cài đặt:

```bash
# Clone dự án về máy cục bộ
git clone https://github.com/baokhanh546123/Condere.git

# Di chuyển vào thư mục dự án
cd condere

# Cấp quyền thực thi và chạy script
chmod +x ./scripts.sh
./scripts.sh