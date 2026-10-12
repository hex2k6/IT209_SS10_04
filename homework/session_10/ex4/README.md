# Bài 4: Custom Bridge Network và Named Volume

## 1. Mục tiêu và mô hình

Kết nối hai container bằng Docker CLI, kiểm tra DNS nội bộ và chứng minh dữ liệu PostgreSQL vẫn còn sau khi xóa container DB.

```text
app-container (Node.js Web API, port 3000)
    |
    | PGHOST=db-server, PGPORT=5432
    | Custom bridge: app-net
    v
db-server (postgres:15-alpine)
    |
    +-- db-data -> /var/lib/postgresql/data
```

Backend truy vấn PostgreSQL thật bằng thư viện `pg`, không chỉ kiểm tra ping. Endpoint `GET /` đọc bảng `persistence_test` và trả JSON. Hai container giao tiếp qua tên `db-server`, không cấu hình IP tĩnh. Bài này không publish cổng lên host; API được kiểm tra từ bên trong container. Vì vậy không chiếm cổng 8080 đang dùng ở bài trước.

## 2. Chạy script

Yêu cầu Docker Engine đang chạy, truy cập được Docker Hub/npm, và có Bash. Trên Windows có thể sử dụng Git Bash với Docker Desktop ở chế độ Linux containers.

Từ thư mục `homework/session_10/ex4/`:

```bash
bash commands.sh
```

Script tự sinh mã nguồn API và Dockerfile trong thư mục tạm rồi build image `hw-network-backend:v1`, nên không cần cài Node.js/npm trên host và không cần tải mã bài 2. Sau khi kết thúc, script dọn các tệp nguồn tạm. Image và tài nguyên Docker được giữ lại để kiểm tra.

Mật khẩu mặc định `local-lab-password` chỉ dùng cho bài thực hành. Có thể đặt biến `POSTGRES_PASSWORD` trước khi chạy để thay đổi. Script truyền biến môi trường sang DB và Backend, không đưa mật khẩu vào image hay in toàn bộ biến môi trường ra log.

Script từ chối chạy nếu đã có container `db-server`/`app-container`, network `app-net` hoặc volume `db-data`, để không ghi đè hoặc xóa dữ liệu có sẵn. Vì vậy không chạy lại nguyên script trên các tài nguyên của lần chạy thành công; dùng các lệnh xác minh ở mục 5.

## 3. Các thao tác chính

### Tạo network và volume

```bash
docker network create --driver bridge app-net
docker volume create db-data
```

### Khởi chạy PostgreSQL

Các biến bên dưới được script khai báo trước khi dùng:

```bash
docker run -d --name db-server --network app-net \
  -e POSTGRES_USER -e POSTGRES_PASSWORD -e POSTGRES_DB \
  -v db-data:/var/lib/postgresql/data postgres:15-alpine
```

Database là `appdb`, user là `appuser`. Script chờ `pg_isready` qua TCP trước khi gửi SQL, với thời gian chờ hữu hạn.

### Ghi dữ liệu và chạy Backend

```sql
CREATE TABLE persistence_test (id integer PRIMARY KEY, message text NOT NULL);
INSERT INTO persistence_test VALUES (1, 'Du lieu ben vung Docker Volume');
```

```bash
docker run -d --name app-container --network app-net \
  -e PGHOST=db-server -e PGPORT=5432 -e PGUSER="$POSTGRES_USER" \
  -e PGPASSWORD -e PGDATABASE="$POSTGRES_DB" hw-network-backend:v1
```

Backend sử dụng `PGHOST=db-server` để kết nối. API được kiểm tra cả trước và sau khi thay container DB; kết quả HTTP và JSON phải đúng, nếu không script trả lỗi.

### Thử Data Persistence

1. Lưu kết quả SELECT và ID container DB ban đầu.
2. Chạy `docker rm -f db-server`.
3. Chạy lại lệnh tạo DB ở trên, gắn **cùng volume `db-data`**.
4. Chờ DB sẵn sàng và SELECT lại dữ liệu.
5. So sánh ID container phải khác nhau, nhưng dữ liệu trước/sau phải giống hệt và đúng bản ghi mong đợi.

Không chạy lại CREATE TABLE hoặc INSERT sau khi tạo lại DB. Do đó kết quả đọc được chứng minh dữ liệu đến từ volume cũ, không phải dữ liệu vừa tạo lại. Việc xóa container không xóa named volume `db-data`.

## 4. Kết quả thực tế

Thực hành ngày 12/10/2026 (Asia/Saigon) bằng Git Bash và Docker Desktop Linux Engine. Script hoàn tất với mã thoát **0**.

| Kiểm tra | Kết quả |
| --- | --- |
| Network | `app-net`, driver `bridge` |
| Volume | `db-data`, driver `local` |
| DB hostname | `db-server` phân giải thành `172.18.0.2` |
| Backend IP | `172.18.0.3` |
| Ping sau khi tái tạo DB | 2 gói gửi, 2 gói nhận, mất 0% |
| ID DB trước | `42fb893f0ac221ed9c8c058922ede752580bd903b0ca7fc0244481528694328b` |
| ID DB sau | `9a43781fc5d8c363b161058559a3c8eb0ab5f7fe37c4b7c5e4fa0ae5277f2598` |
| Dữ liệu trước và sau | `1\|Du lieu ben vung Docker Volume` |
| API trước và sau | HTTP 200, cùng bản ghi từ PostgreSQL |

Các IP là giá trị ở lần chạy này, có thể khác ở máy khác. Backend dùng hostname nên không phụ thuộc các IP ghi trong bảng.

## 5. Lệnh xác minh sau khi chạy

```bash
docker network ls | grep app-net
docker volume ls | grep db-data
docker network inspect app-net
docker exec -it app-container ping -c 2 db-server
docker exec db-server psql -U appuser -d appdb -c 'SELECT * FROM persistence_test;'
docker exec app-container node -e 'fetch("http://127.0.0.1:3000/").then(async r => console.log(r.status, await r.text()))'
```

Trong script tự động, lệnh ping dùng `docker exec app-container ping -c 2 db-server` (bỏ `-it` vì không có terminal tương tác). Tác dụng kiểm tra DNS và ICMP không thay đổi.

## 6. Log thực thi

Đầu ra thực tế dưới đây chỉ bỏ khoảng trắng cuối dòng khi trình bày Markdown:

```text
=== Build backend ===
#0 building with "desktop-linux" instance using docker driver

#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 221B 0.0s done
#1 DONE 0.1s

#2 [internal] load metadata for docker.io/library/node:18-alpine
#2 DONE 0.4s

#3 [internal] load .dockerignore
#3 transferring context: 2B done
#3 DONE 0.0s

#4 [internal] load build context
#4 transferring context: 1.11kB done
#4 DONE 0.0s

#5 [1/5] FROM docker.io/library/node:18-alpine@sha256:8d6421d663b4c28fd3ebc498332f249011d118945588d0a35cb9bc4b8ca09d9e
#5 resolve docker.io/library/node:18-alpine@sha256:8d6421d663b4c28fd3ebc498332f249011d118945588d0a35cb9bc4b8ca09d9e 0.0s done
#5 DONE 0.1s

#6 [2/5] WORKDIR /app
#6 CACHED

#7 [3/5] COPY package.json ./
#7 DONE 0.0s

#8 [4/5] RUN npm install --omit=dev --no-audit --no-fund
#8 3.428
#8 3.428 added 13 packages in 2s
#8 3.430 npm notice
#8 3.430 npm notice New major version of npm available! 10.8.2 -> 12.2.0
#8 3.430 npm notice Changelog: https://github.com/npm/cli/releases/tag/v12.2.0
#8 3.430 npm notice To update run: npm install -g npm@12.2.0
#8 3.430 npm notice
#8 DONE 3.5s

#9 [5/5] COPY server.js ./
#9 DONE 0.1s

#10 exporting to image
#10 exporting layers
#10 exporting layers 0.2s done
#10 exporting manifest sha256:7d02d41e7048f85bdf8abd7edf3cd8ff5e7bf91a6b4f490edd262ab8b4f7438d 0.0s done
#10 exporting config sha256:4953ab0790289b3ad5b93c2defd17497bd6853849cca18258a3d63edc2d84c60 0.0s done
#10 exporting attestation manifest sha256:4110c33c60f3052f90b9e28fc725606582206973ff9c1f9b44709ab5bf8df106 0.0s done
#10 exporting manifest list sha256:347831342b89a5ae575a0cb174fbd1d38bf974f6e7c4d4ae204fba89dec6f567 0.0s done
#10 naming to docker.io/library/hw-network-backend:v1 done
#10 unpacking to docker.io/library/hw-network-backend:v1
#10 unpacking to docker.io/library/hw-network-backend:v1 0.2s done
#10 DONE 0.5s
=== Create network and volume ===
1fdcb60f0082b9d725897c7da0ae30cb2e815e1a020e33465965633a3b73cd47
db-data
=== Start database and insert data ===
Unable to find image 'postgres:15-alpine' locally
15-alpine: Pulling from library/postgres
277e2289225f: Pulling fs layer
3f49193fd82d: Pulling fs layer
2e9987a42d41: Pulling fs layer
2c2e40dd947e: Pulling fs layer
0976f43b012c: Pulling fs layer
4f83103187f5: Pulling fs layer
c020dab2e853: Pulling fs layer
e9516be90840: Pulling fs layer
6ba2251a51ae: Pulling fs layer
bc2205dd5a3a: Pulling fs layer
277e2289225f: Download complete
3f49193fd82d: Download complete
2c2e40dd947e: Download complete
4f83103187f5: Download complete
2e9987a42d41: Download complete
0976f43b012c: Download complete
c020dab2e853: Download complete
6ba2251a51ae: Download complete
bc2205dd5a3a: Download complete
2c2e40dd947e: Pull complete
3f49193fd82d: Pull complete
2e9987a42d41: Pull complete
bc2205dd5a3a: Pull complete
697de61d3cc1: Download complete
d3e3f1b947dc: Download complete
e9516be90840: Download complete
e9516be90840: Pull complete
277e2289225f: Pull complete
4f83103187f5: Pull complete
0976f43b012c: Pull complete
c020dab2e853: Pull complete
6ba2251a51ae: Pull complete
Digest: sha256:f7d23353e1b15400d22ebe31189f4d314b87a4c129cc400c8c2d8d4ca127bf81
Status: Downloaded newer image for postgres:15-alpine
42fb893f0ac221ed9c8c058922ede752580bd903b0ca7fc0244481528694328b
CREATE TABLE
INSERT 0 1
 id |            message
----+--------------------------------
  1 | Du lieu ben vung Docker Volume
(1 row)

=== Start backend with DB hostname ===
f56ef652e7803401bf84f163bc9986f3840f53448f08ccb0878a6c0859dbb8f8
HTTP 200
{"status":"success","dbHost":"db-server","rows":[{"id":1,"message":"Du lieu ben vung Docker Volume"}]}
=== DNS before recreation ===
PING db-server (172.18.0.2): 56 data bytes
64 bytes from 172.18.0.2: seq=0 ttl=42 time=0.417 ms
64 bytes from 172.18.0.2: seq=1 ttl=42 time=0.160 ms

--- db-server ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.160/0.288/0.417 ms
=== Force-remove only the database container ===
db-server
=== Recreate database using the same named volume ===
9a43781fc5d8c363b161058559a3c8eb0ab5f7fe37c4b7c5e4fa0ae5277f2598
Old container ID: 42fb893f0ac221ed9c8c058922ede752580bd903b0ca7fc0244481528694328b
New container ID: 9a43781fc5d8c363b161058559a3c8eb0ab5f7fe37c4b7c5e4fa0ae5277f2598
Before: 1|Du lieu ben vung Docker Volume
After: 1|Du lieu ben vung Docker Volume
=== Backend query after recreation ===
HTTP 200
{"status":"success","dbHost":"db-server","rows":[{"id":1,"message":"Du lieu ben vung Docker Volume"}]}
=== Required network and volume checks ===
1fdcb60f0082   app-net   bridge    local
local     db-data
[
    {
        "Name": "app-net",
        "Id": "1fdcb60f0082b9d725897c7da0ae30cb2e815e1a020e33465965633a3b73cd47",
        "Created": "2026-10-12T16:41:29.153472948Z",
        "Scope": "local",
        "Driver": "bridge",
        "EnableIPv4": true,
        "EnableIPv6": false,
        "IPAM": {
            "Driver": "default",
            "Options": {},
            "Config": [
                {
                    "Subnet": "172.18.0.0/16",
                    "Gateway": "172.18.0.1"
                }
            ]
        },
        "Internal": false,
        "Attachable": false,
        "Ingress": false,
        "ConfigFrom": {
            "Network": ""
        },
        "ConfigOnly": false,
        "Options": {
            "com.docker.network.enable_ipv4": "true",
            "com.docker.network.enable_ipv6": "false"
        },
        "Labels": {},
        "Containers": {
            "9a43781fc5d8c363b161058559a3c8eb0ab5f7fe37c4b7c5e4fa0ae5277f2598": {
                "Name": "db-server",
                "EndpointID": "6e03683fbfe8b0f385be517e43abd4743bddf3b72bba6af340033036e008df87",
                "MacAddress": "fa:f4:22:8e:9e:91",
                "IPv4Address": "172.18.0.2/16",
                "IPv6Address": ""
            },
            "f56ef652e7803401bf84f163bc9986f3840f53448f08ccb0878a6c0859dbb8f8": {
                "Name": "app-container",
                "EndpointID": "7465c116abc2063bbb06446eb278b6ed6e73e7528f322155b047ad987e75043a",
                "MacAddress": "16:ba:a1:e2:22:fd",
                "IPv4Address": "172.18.0.3/16",
                "IPv6Address": ""
            }
        },
        "Status": {
            "IPAM": {
                "Subnets": {
                    "172.18.0.0/16": {
                        "IPsInUse": 5,
                        "DynamicIPsAvailable": 65531
                    }
                }
            }
        }
    }
]
PING db-server (172.18.0.2): 56 data bytes
64 bytes from 172.18.0.2: seq=0 ttl=42 time=0.849 ms
64 bytes from 172.18.0.2: seq=1 ttl=42 time=0.101 ms

--- db-server ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.101/0.475/0.849 ms
CONTAINER ID   IMAGE                   COMMAND                  CREATED         STATUS         PORTS      NAMES
9a43781fc5d8   postgres:15-alpine      "docker-entrypoint.s…"   5 seconds ago   Up 4 seconds   5432/tcp   db-server
f56ef652e780   hw-network-backend:v1   "docker-entrypoint.s…"   9 seconds ago   Up 8 seconds   3000/tcp   app-container
PASS: DNS resolved, backend queried PostgreSQL, data survived DB container replacement.
```

**Kết luận:** Hai container giao tiếp qua DNS của custom bridge network. Bản ghi PostgreSQL nguyên vẹn sau khi xóa cứng container DB và tạo container mới gắn cùng named volume. Giữ lại hai container, network và volume để có thể kiểm tra lại.