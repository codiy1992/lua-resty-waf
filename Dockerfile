FROM debian:buster

# ------------------------------------------------------------------------
# Install requirements
# ------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        vim \
        sudo \
        curl \
        wget \
        supervisor

# ------------------------------------------------------------------------
# Install OpenResty
# See: https://openresty.org/cn/installation.html
# See: https://openresty.org/cn/linux-packages.html
# ------------------------------------------------------------------------
RUN addgroup --system --gid 101 nginx
RUN adduser --system --disabled-login --ingroup nginx --no-create-home --home \
    /nonexistent --gecos "nginx user" --shell /bin/false --uid 101 nginx
RUN apt-get -y install --no-install-recommends wget gnupg ca-certificates
RUN wget --no-check-certificate -O - https://openresty.org/package/pubkey.gpg | sudo apt-key add -
RUN apt-get -y install --no-install-recommends software-properties-common
RUN codename=`grep -Po 'VERSION="[0-9]+ \(\K[^)]+' /etc/os-release` && \
    arch=$(arch | sed s/aarch64/arm64\\// | sed s/x86_64//) && \
    echo "deb http://openresty.org/package/${arch}debian $codename openresty" \
    | sudo tee /etc/apt/sources.list.d/openresty.list
RUN apt-get update && apt-get -y install openresty

# ------------------------------------------------------------------------
# Install openresty lua package: lua-resty-jwt
# See: https://github.com/SkyLothar/lua-resty-jwt
# ------------------------------------------------------------------------
RUN opm get SkyLothar/lua-resty-jwt

# ------------------------------------------------------------------------
# Supervisor Configuration
# ------------------------------------------------------------------------
SHELL ["/bin/bash", "-c"]
RUN echo $'[program:nginx] \n\
command=/usr/local/openresty/nginx/sbin/nginx -c /usr/local/openresty/nginx/conf/nginx.conf -g "daemon off;" \n\
process_name=%(program_name)s \n\
numprocs=1 \n\
startsecs=3 \n\
autostart=true \n\
autorestart=true \n\
priority=999 \n\
user=root \n\
umask=0000 \n\
stdout_logfile=/dev/stdout \n\
stderr_logfile=/dev/stdout \n\
stdout_logfile_maxbytes=0 \n\
stderr_logfile_maxbytes=0 \n\
' > /etc/supervisor/conf.d/nginx.conf

# ------------------------------------------------------------------------
# Start Services
# ------------------------------------------------------------------------
RUN mkdir -p /data/storage/logs

WORKDIR /data

STOPSIGNAL SIGQUIT

CMD ["supervisord", "--nodaemon"]
