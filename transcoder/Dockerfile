FROM alpine:3.21

# ffmpeg / ffprobe。alpine の ffmpeg は libx264 と hls マキサー込み。
RUN apk add --no-cache ffmpeg tini

COPY run.sh /opt/run.sh

# Windows で編集された run.sh が CRLF で来ても壊れないようにする。
# (ここを入れないと "bad interpreter" や謎の構文エラーになる)
RUN sed -i 's/\r$//' /opt/run.sh && chmod +x /opt/run.sh

# tini を挟まないと docker compose stop で ffmpeg が居座って 10 秒待たされる。
# -g はプロセスグループ全体に signal を転送する指定。これが無いと
# シェルだけ死んで ffmpeg が残ります。
ENTRYPOINT ["/sbin/tini", "-g", "--", "/opt/run.sh"]
