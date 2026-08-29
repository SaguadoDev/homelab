# Tailscale

Tailscale es la única puerta de entrada al servidor. **No hay ni un solo
puerto abierto en el router.**

## Qué hace aquí

1. **Red privada.** Cada dispositivo mío entra en el tailnet y llega al
   servidor por su nombre MagicDNS. Fuera del tailnet el servidor no
   existe.
2. **Terminación TLS.** `tailscale serve` pone delante de cada servicio un
   certificado real de Let's Encrypt para `<host>.<tailnet>.ts.net`,
   emitido y **renovado por tailscaled sin intervención**.
3. **Nodo de salida.** El servidor anuncia `0.0.0.0/0` y `::/0`, así que
   desde el móvil en una wifi pública puedo salir a internet por casa.

## Publicación de servicios

```bash
# Vaultwarden en el 443 (el puerto por defecto del nombre MagicDNS)
sudo tailscale serve --bg --https=443 http://127.0.0.1:8080

# API de Vault App en el 8443
sudo tailscale serve --bg --https=8443 http://127.0.0.1:3000

sudo tailscale serve status
```

Queda:

```
https://<host>.<tailnet>.ts.net        -> 127.0.0.1:8080   (Vaultwarden)
https://<host>.<tailnet>.ts.net:8443   -> 127.0.0.1:3000   (API Vault App)
```

La configuración persiste en el estado de tailscaled: sobrevive a
reinicios sin necesidad de ninguna unidad de systemd propia.

`serve` es *tailnet only*. Lo que expondría a internet es `tailscale
funnel`, y aquí está deliberadamente apagado.

## Certificados: no hay nada que programar

Los certificados los gestiona tailscaled en su propio almacén
(`/var/lib/tailscale/certs`) y los renueva solo mediante la extensión
`acme`, que consulta ARI a Let's Encrypt.

Es un error frecuente —lo cometí— generar los ficheros a mano:

```bash
sudo tailscale cert <host>.<tailnet>.ts.net    # escribe .crt y .key en el cwd
```

Eso produce **una copia estática** que caduca a los 90 días y que **nadie
renueva**. Solo tiene sentido si vas a montar los ficheros en un servicio
que termine TLS por su cuenta (nginx, Caddy) y montas también su
renovación. Si usas `tailscale serve`, esos ficheros sobran: bórralos
antes de que dentro de un año alguien los encuentre y los dé por válidos.

## Comprobaciones

```bash
tailscale status                 # nodos del tailnet y si se ofrece exit node
tailscale serve status           # qué se publica y hacia dónde
tailscale dns status             # MagicDNS y rutas split-DNS

# Qué certificado se está sirviendo de verdad
echo | openssl s_client -connect <host>.<tailnet>.ts.net:443 \
  -servername <host>.<tailnet>.ts.net 2>/dev/null \
  | openssl x509 -noout -subject -dates
```
