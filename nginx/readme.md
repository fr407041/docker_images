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
>
> Below is my setting
>
![](/nginx/image/nginx_01.png)


### Revise Nginx log format
>
> Add in `/etc/nginx/nginx.conf`
>
```
# Type 1
log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                  '$status $body_bytes_sent "$http_referer" '
                  '"$http_user_agent" "$http_x_forwarded_for"';
# Type 2 (separate by ",")
log_format  main  '"$remote_addr" , "$remote_user" , "$time_local" , "$request" , "$status" , "$body_bytes_sent" , "$http_referer" , "$http_user_agent" , "$http_x_forwarded_for"';
```
>
> Below is my setting (Mine is Type 2)
>
![](/nginx/image/nginx_conf.png)


### Revise default.conf 
>
> Add in `/etc/nginx/conf.d/default.conf`
>
```
autoindex on;               # Enable Browse Index
autoindex_exact_size off;   # Default : on  `size unit by bytes`， off `size unit by kB、MB、GB`
autoindex_localtime on;     # Default : off `Revise Time is GMT`， on  `Revise Time is Server Location Time`。
```
>
> Below is my setting (Mine is Type 2)
>
![](/nginx/image/nginx_default.png)

