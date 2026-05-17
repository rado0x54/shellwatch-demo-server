# SPDX-License-Identifier: MIT
# syntax=docker/dockerfile:1.7

# Build nudoku from source. Not packaged for Alpine, and we want to skip
# the optional Cairo dependency (only used for PNG export, irrelevant
# in a terminal-only image).
FROM alpine:3.20 AS nudoku-build
RUN apk add --no-cache \
      build-base autoconf automake libtool gettext-dev ncurses-dev \
      git pkgconf
WORKDIR /src
RUN git clone --depth 1 https://github.com/jubalh/nudoku.git
WORKDIR /src/nudoku
RUN autoreconf -i && \
    ./configure --prefix=/usr --disable-cairo --disable-nls && \
    make -j"$(nproc)" && \
    make install DESTDIR=/out


# Build mevdschee/2048.c from source. Not packaged for Alpine (the
# gnome-2048/libretro-2048 hits are unrelated). Single C file, libc only.
FROM alpine:3.20 AS twentyfortyeight-build
RUN apk add --no-cache build-base git
WORKDIR /src
RUN git clone --depth 1 https://github.com/mevdschee/2048.c
WORKDIR /src/2048.c
RUN make -j"$(nproc)" && make install PREFIX=/usr DESTDIR=/out


FROM alpine:3.20

ARG DEMO_USERS="sw-snake sw-matrix sw-sudoku sw-2048"

RUN apk add --no-cache \
      openssh-server \
      bsd-games cmatrix \
      ncurses \
      curl \
      tini

# nudoku + 2048 binaries from the build stages
COPY --from=nudoku-build /out/usr/ /usr/
COPY --from=twentyfortyeight-build /out/usr/ /usr/

# One Linux user per principal. /bin/ash so ForceCommand works (nologin would
# cause sshd to skip ForceCommand). -H avoids creating per-user home dirs;
# /var/empty stays root-owned (sshd privilege separation requires this).
# Replace the busybox-default "!" lock marker with "*" so sshd doesn't reject
# the account as locked. "*" means "no valid password" — safe because
# PasswordAuthentication is off, so only pubkey auth can succeed.
RUN mkdir -p /var/empty && chown root:root /var/empty && chmod 0755 /var/empty && \
    for u in $DEMO_USERS; do \
      adduser -D -H -s /bin/ash -h /var/empty "$u"; \
      sed -i "s|^${u}:!:|${u}:*:|" /etc/shadow; \
    done

# authorized_keys directory: one empty file per principal.
# Mounted read-only at runtime by ShellWatch's authorizedKeyFile delivery.
RUN mkdir -p /var/lib/demo/keys && \
    for u in $DEMO_USERS; do \
      install -o "$u" -g "$u" -m 0644 /dev/null "/var/lib/demo/keys/$u"; \
    done

# Host-key directory. Lives outside /etc/ssh so a persistence volume can
# be mounted without shadowing sshd_config. entrypoint.sh populates it.
RUN mkdir -p /var/lib/demo/host-keys && chmod 700 /var/lib/demo/host-keys

COPY sshd_config /etc/ssh/sshd_config
COPY payloads/ /usr/local/lib/demo/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/lib/demo/*.sh

EXPOSE 22
ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
