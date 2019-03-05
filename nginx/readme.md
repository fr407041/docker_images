# NGINX Note
***
### Pull Image From Docker Hub
```
docker pull nginx
```

### Docker Run Command
```
docker run -d \
-p 8080:80 \
--name nginx \
--restart always \
-v /media/sf_docker/image/nginx:/usr/share/nginx/html:ro \
-v /media/sf_docker/image/nginx/nginx_setting/default.conf:/etc/nginx/conf.d/default.conf:ro \
-v /media/sf_docker/image/nginx/nginx_setting/nginx.conf:/etc/nginx/nginx.conf:ro \
-v /media/sf_docker/image/nginx/log:/var/log/nginx \
my_nginx:0.0.1
```

### Dockerfile 
```
# sudo docker build -t="my_nginx:0.0.1" .
FROM nginx
MAINTAINER bochen shih "fr407041@gmail.com"

RUN groupadd -g 996 vboxsf \
&& usermod -a -G vboxsf nginx 
```
>
> By below command, you can see the inner setting of container
>
> `docker exec -it nginx bash`
>

### Nginx log setting and location
>
> log location at container : `/var/log/nginx/access.log` & `/var/log/nginx/error.log`
>
> log setting at container : `/etc/nginx/nginx.conf`
>
```
# add in /etc/nginx/conf.d/default.conf (save log name by Year-Month-Day-access.log , ex: 2019-03-03-access.log )
if ($time_iso8601 ~ "^(\d{4})-(\d{2})-(\d{2})") {
  set $date $1-$2-$3;
}

access_log   /var/log/nginx/$date-access.log debug;
```

### Revise Nginx log format
>
> Edit in `/etc/nginx/nginx.conf`
>
```
# Type 1
log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                  '$status $body_bytes_sent "$http_referer" '
                  '"$http_user_agent" "$http_x_forwarded_for"';
# Type 2
log_format  main  '"$remote_addr" , "$remote_user" , "$time_local" , "$request" , "$status" , "$body_bytes_sent" , "$http_referer" , "$http_user_agent" , "$http_x_forwarded_for"';
```

### Nginx Command Explain
>
> usr/share/nginx/html :網頁根目錄
>
> vi /etc/yum.repos.d/nginx.repo
>
> autoindex on;  開啟瀏覽目錄
>
> autoindex_exact_size off;   預設為 on 會顯示檔案大小單位為 bytes，off 單位為 kB、MB、GB
>
> autoindex_localtime on;   預設為 off 顯示檔案修改時間為 GMT，on 則為 Server 地區時間。
>
