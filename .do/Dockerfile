FROM alpine

RUN apk add socat

CMD socat TCP-LISTEN:$PORT,fork,reuseaddr TCP:electric:$PG_PROXY_PORT
