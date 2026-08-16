__HOOK_DOMAIN__ {
    encode gzip zstd

    @telegram path /webhook /webhook/*
    handle @telegram {
        reverse_proxy 127.0.0.1:__BOT_HTTP_PORT__
    }

    @remnawave path /remnawave-webhook /remnawave-webhook/*
    handle @remnawave {
        reverse_proxy 127.0.0.1:__BOT_HTTP_PORT__
    }

    respond 404
}

__APP_DOMAIN__ {
    encode gzip zstd

    request_body {
        max_size 50MB
    }

    route {
        @health path /health/unified
        handle @health {
            reverse_proxy 127.0.0.1:__BOT_HTTP_PORT__
        }

        @api path /api /api/*
        handle @api {
            uri strip_prefix /api
            reverse_proxy 127.0.0.1:__BOT_HTTP_PORT__
        }

        @cabinet_backend path /cabinet /cabinet/*
        handle @cabinet_backend {
            reverse_proxy 127.0.0.1:__BOT_HTTP_PORT__
        }

        @uploads path /uploads /uploads/*
        handle @uploads {
            uri strip_prefix /uploads
            root * __BOT_UPLOADS_DIR__
            header Cache-Control "public, max-age=2592000, no-transform"
            file_server
        }

        handle {
            root * __CABINET_DIST_DIR__

            @static path *.js *.css *.woff *.woff2 *.ttf *.ico *.png *.jpg *.jpeg *.svg *.webp *.gif
            header @static Cache-Control "public, max-age=31536000, immutable"

            @html path / *.html
            header @html Cache-Control "no-cache, must-revalidate"

            try_files {path} /index.html
            file_server
        }
    }
}
