# Arquitectura

## Hardware

Un mini PC de sobremesa reutilizado. No es un NAS ni un rack: es el
ordenador que había, con el consumo de una bombilla.

| | |
|---|---|
| Equipo | Lenovo ThinkCentre M715q |
| CPU | AMD Ryzen 5 PRO 2400GE |
| RAM | 16 GB |
| Disco | NVMe 256 GB |
| SO | Ubuntu 26.04 LTS |
| Red | Ethernet a 1 Gb, IP fija por reserva DHCP en el router |

Dimensionar esto de más es el error clásico del homelab. Con cuatro
contenedores, un bot y Postgres, el consumo en reposo es de ~2 GiB de RAM
y prácticamente nada de CPU. El cuello de botella no es la máquina.

## Plano general

```mermaid
flowchart LR
    subgraph fuera ["Fuera de casa"]
        movil["Móvil"]
    end

    subgraph lan ["Red local"]
        router["Router<br/>DHCP anuncia el servidor como DNS"]
        disp["PCs · móviles · TV"]
    end

    subgraph tailnet ["Tailnet — WireGuard"]
        tsd["tailscaled<br/>MagicDNS · serve · exit node"]
    end

    subgraph host ["Servidor — Ubuntu 26.04"]
        bot["Bot de Telegram<br/>systemd"]
        subgraph docker ["Docker"]
            adg["AdGuard Home<br/>network_mode host<br/>:53 · :80"]
            vw["Vaultwarden<br/>127.0.0.1:8080"]
            api["Vault App API<br/>127.0.0.1:3000"]
            pg[("PostgreSQL 16<br/>sin puerto publicado")]
        end
    end

    subgraph ext ["Servicios externos"]
        doh["DNS-over-HTTPS<br/>Quad9 · Cloudflare"]
        drive["Google Drive<br/>copias cifradas GPG"]
        tg["Telegram"]
    end

    movil -->|"https"| tsd
    movil -.->|"exit node"| tsd
    router -.-> disp
    disp -->|"DNS :53"| adg
    tsd -->|":443"| vw
    tsd -->|":8443"| api
    api --> pg
    adg -->|"DoH"| doh
    bot -.->|"docker inspect"| docker
    bot -->|"alertas"| tg
    vw -.->|"03:00"| drive
    api -.->|"04:30"| drive
```

## Los tres caminos de entrada

Solo el primero atraviesa la frontera de casa.

**1. Desde fuera — Tailscale.** El móvil se conecta al tailnet y llega a
`https://<host>.<tailnet>.ts.net`. TLS real, sin puertos abiertos en el
router, sin DNS dinámico, sin túnel de terceros. Si el dispositivo no
está en el tailnet, el servidor no existe para él.

**2. Desde la red local — DNS.** El router reparte por DHCP la IP del
servidor como DNS. Todos los dispositivos de casa resuelven contra
AdGuard sin configurar nada en cada uno.

**3. Desde el propio host — loopback.** Vaultwarden y la API de Vault
publican sus puertos **solo** en `127.0.0.1`. Quien los saca al tailnet es
`tailscale serve`, que corre en el host y por tanto los ve por loopback.
Ningún servicio de aplicación es alcanzable directamente desde la LAN.

## Flujo de una consulta DNS

```mermaid
sequenceDiagram
    participant D as Dispositivo LAN
    participant A as AdGuard en el 53
    participant T as MagicDNS 100.100.100.100
    participant U as Quad9 y Cloudflare por DoH

    D->>A: ¿ejemplo.com?
    alt está en una lista de bloqueo
        A-->>D: respuesta bloqueada
    else es *.ts.net
        A->>T: reenvía por regla split-DNS
        T-->>A: IP del tailnet
        A-->>D: IP del tailnet
    else cualquier otra
        A->>U: DoH cifrado, dos upstreams en paralelo
        U-->>A: respuesta
        A-->>D: respuesta y a cache
    end
```

La regla `[/ts.net/]100.100.100.100` es la que hace que los nombres
MagicDNS funcionen también para los clientes que usan AdGuard como DNS.
Sin ella, un dispositivo de la LAN resuelve todo internet pero no
encuentra el propio servidor por su nombre de tailnet.

## Redes de Docker

| Red | Quién | Por qué |
|---|---|---|
| `host` | AdGuard Home | Necesita ver la IP de origen real de cada consulta; a través del bridge todas llegarían con la IP de la pasarela y las estadísticas por cliente dejarían de existir |
| bridge propio | Vaultwarden | Aislado, con el puerto publicado solo en loopback |
| bridge propio | Vault App (api + postgres) | Postgres **no publica ningún puerto**: solo la API lo alcanza, por el nombre de servicio dentro de la red del compose |

Que Postgres no exponga puerto no es un detalle: es la razón por la que
la base de datos no necesita defenderse de nada. Su única superficie es
la API.
