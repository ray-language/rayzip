# rayzip

Archivos ZIP y gzip, compatibles con `zip`, `unzip` y `gzip`, escrito en
[raylang](https://github.com/ray-language/raylang). Comprime en paralelo con fibras, lee los archivos
del disco por partes (ZIP64 incluido) y trata cada archivo como entrada hostil al extraer.

```
rayzip c fotos.zip fotos/          # crear (directorios recursivos)
rayzip l fotos.zip                 # listar
rayzip t fotos.zip                 # probar: leer todo y comprobar tamaños y CRC-32
rayzip x fotos.zip -d destino/     # extraer
rayzip gzip datos.csv              # datos.csv → datos.csv.gz
rayzip gunzip datos.csv.gz         # y de vuelta
```

Opciones: `-d DIR` destino de la extracción · `-o` sobrescribir al extraer · `-0` sin compresión ·
`-j N` fibras de compresión (por defecto una por núcleo) · `--max-deflate S` los archivos más grandes
que `S` se guardan sin comprimir (por defecto `512M`; acepta `K`, `M`, `G`) · `-c OUT` salida de
gzip/gunzip · `-q` silencioso.

## Qué hace

- **Crea** archivos que leen `unzip`, `zipinfo`, `std/zip`, `tar.exe` y `Expand-Archive`: deflate o
  stored, lo que ocupe menos (lo ya comprimido va tal cual). Lleva el modo Unix (los permisos
  sobreviven), la fecha en hora local (con el paquete `tz`, también en Windows) y el campo
  extendido `UT` en UTC, y marca los nombres UTF-8. Los nombres van sin letra de unidad.
- **Lee los nombres** en UTF-8 o, si no lo son, en CP437 (lo que escriben `tar.exe` y
  `Compress-Archive` de Windows), con el campo Unicode Path de Info-ZIP si viene.
- **Comprime en paralelo**: `-j N` fibras leen y deflan archivos por delante del escritor, que los
  pone en orden. El resultado es idéntico byte a byte con cualquier `-j`.
- **ZIP64**: más de 65 535 entradas, o tamaños y posiciones de más de 4 GiB.
- **Lee del disco sin cargar el archivo**: la cola y el directorio central con `fs.seek`, y cada
  entrada por partes.
- **Extrae con cuidado**: rechaza nombres absolutos, con `..` o con letra de unidad. Los symlinks
  del archivo solo pueden apuntar dentro del destino, y un symlink ya presente en disco no puede
  desviar una entrada posterior (`fs.is_within_real`). Un archivo existente se reemplaza, no se
  escribe a través de él. Se quitan los bits setuid/setgid/sticky. La descompresión se corta en el
  tamaño declarado (bombas zip). No sobrescribe sin `-o`.
- **gzip en miembros de 4 MiB**, deflados en paralelo. `gzip -d` los concatena. Cada miembro lleva
  su longitud en un subcampo extra `RZ` (como el `BC` de BGZF), así que leerlos es una descompresión
  rápida por miembro. Los `.gz` de otras herramientas (un miembro) también se leen.

## Cómo

```
src/main.ray      la línea de órdenes
src/sources.ray   qué entra: el recorrido de directorios y el nombre de cada entrada
src/create.ray    escribir: fibras que deflan, el escritor en orden, los grandes por trozos
src/archive.ray   leer: registros del final, directorio central, datos por entrada
src/extract.ray   extraer y probar, con las comprobaciones de seguridad
src/format.ray    los registros ZIP y ZIP64 (codificar y decodificar, sin E/S)
src/gz.ray        gzip: miembros con longitud, compresión en paralelo, lectura
src/dostime.ray   fecha y hora DOS en la zona del sistema (paquete tz)
src/le.ray        enteros little-endian
```

La stdlib trae las piezas de bajo nivel (`deflate_raw`, `inflate_raw`, `crc32`, `inflate_stream`)
pero no un zip completo: `std/zip` solo lee, en memoria y sin ZIP64. Así que rayzip implementa el
formato y usa `std/zip` en los tests como lector independiente de lo que escribe. Las decisiones
vienen de lo que falta (ver hallazgos):

- **Comprimir es en memoria.** `std/deflate` no tiene compresor por streaming, así que cada archivo
  se lee y se defla entero. Por encima de `--max-deflate` se guarda sin comprimir, copiado por trozos
  de 1 MiB con la CRC escrita después en la cabecera local (`fs.seek` sobre el handle de escritura).
- **Descomprimir una entrada de hasta 64 MiB comprimidos es una llamada** (`inflate_raw_limit`, con
  el tamaño declarado como límite). Las más grandes van por `inflate_stream`, con memoria acotada.
  **Con raylang 1.27.73 eso falla**: el decodificador por trozos pierde datos (#223), y rayzip da esas
  entradas por corruptas (lo nota por el tamaño y la CRC; nunca escribe datos malos).
- **La CRC por trozos** es `inflate.crc32_update`.

## Uso

```bash
make build         # ./rayzip, binario nativo
make test          # 36 tests en la VM (los de compatibilidad usan zip/unzip/gzip, o en Windows tar.exe y PowerShell)
make test-native   # los mismos, compilados
make bench         # contra zip/unzip/gzip en un corpus generado
```

## Rendimiento

`make bench` en un MacBook (Apple Silicon, 10 núcleos), binario nativo de raylang 1.27.65, frente a
`zip` 3.0, `unzip` 6.00 y `gzip` de macOS. Corpus de texto (una lista de palabras, ~3,3:1):

| Qué | rayzip | herramienta del sistema |
|---|---:|---:|
| 25 archivos de 1 MB, `c -j 1` | 0,83 s · 11 MB | `zip -r` 0,87 s · 1 MB |
| ídem, `-j 4` / `-j 8` | 0,23 s / 0,15 s · 45 MB | |
| 256 MiB, `c` (deflate en memoria) | 8,4 s · 520 MB | `zip` 9,3 s · 1 MB |
| 256 MiB, `c --max-deflate 100M` (stored) | 0,62 s · 9 MB | |
| 256 MiB, `t` (80 MB comprimidos: streaming) | 9,1 s · 170 MB | `unzip -t` 1,4 s · 2 MB |
| 256 MiB, `gzip` (10 fibras) | 1,3 s · 204 MB | `gzip` 9,1 s · 1 MB |
| 256 MiB, `gunzip` de rayzip (miembros) | 1,2 s · 24 MB | `gzip -d` 0,35 s · 1 MB |
| 256 MiB, `gunzip` de `gzip` (un miembro) | 8,9 s · 120 MB | |

El tamaño comprimido es el de `zip`/`gzip` ±0,3 % (81,4 MB frente a 81,2 MB). Comprimir en paralelo
escala casi lineal hasta 4 fibras. Descomprimir un stream grande es lo lento: `inflate_stream` está
escrito en raylang (hallazgo #189).

## Estado

| Qué | Estado |
|---|---|
| Crear, listar, probar, extraer; gzip y gunzip | **36 tests** en VM y nativo (raylang 1.27.73) en macOS, Linux y Windows 11 ARM64, con `std/zip` de oráculo |
| Entradas de más de 64 MiB comprimidos | **fallan con raylang 1.27.73** («corrupt DEFLATE stream», #223); con 1.27.65 funcionaban |
| Compatibilidad | `unzip -t`/`unzip` leen lo que escribe (contenido, modos, ZIP64 de 66 000 entradas); rayzip lee lo de `zip -r`, `zip -ry` (symlinks) y `zip -r0`; `gzip -t`/`-d` leen sus miembros y rayzip los `.gz` de `gzip` |
| Seguridad al extraer | zip-slip (`..`, absolutos, unidades, `\`), symlinks fuera, symlinks plantados, bombas, setuid, archivos truncados: tests en `tests/safety_test.ray` |
| ZIP64 por tamaño (> 4 GiB) | codificado y decodificado en tests de formato; **sin probar** con un archivo real de más de 4 GiB |
| Windows | **verificado** (21 oct 2026, VM UTM con Windows 11 ARM64): la suite en VM y nativo; `tar.exe` y `Expand-Archive` extraen lo que escribe rayzip y rayzip lo de `tar -a` y `Compress-Archive`. Sin permisos (Windows no tiene `chmod`). Con raylang 1.27.73, la hora DOS es la local (#200), los symlinks se crean con `/` (#198) y `rayzip.exe` compila en arm64 (#197) |

Pendiente para una v2: guardar symlinks al crear (`fs.read_link`), restaurar fechas al extraer
(`fs.set_mtime`), comprimir con memoria acotada (`deflate_raw_chunk`), leer los gzip de varios
miembros de otras herramientas, y cifrado.

## Hallazgos de dogfood

En `findings/open/rayzip-1.27.65.md` del directorio de las apps (#188–#200), y la re-medición con
raylang 1.27.73 en `findings/open/rayzip-1.27.73.md`:

1. **#188 [B]** ✅ `inflate.gunzip` daba «CRC32 mismatch (corrupt gzip)» con un gzip válido de varios
   miembros (el de rayzip, o dos `gzip_compress` concatenados).
2. **#189 [E]** ❌ El inflate por streaming era raylang puro: 15× más lento que el de una llamada en
   nativo y 1350× en la VM. En 1.27.73 pasó al runtime, pero pierde datos (#223).
3. **#190 [E]** ✅ `std/deflate` no comprimía por streaming ni tenía nivel: 256 MiB pedían 520 MB.
   Ahora hay `deflate_raw_chunk` y `deflate_raw_level` (rayzip aún no los usa).
4. **#191 [E]** ✅ `std/inflate` no decía cuánta entrada consumió un stream: por eso el campo `RZ`.
5. **#192 [E]** ✅ CRC-32 solo de una vez: hizo falta `crc32_combine` a mano. Ahora `crc32_update`.
6. **#193 [E]** ⚠️ `std/zip` solo lee, en memoria y sin ZIP64. El paquete `zip`, sacado de rayzip, lee
   y escribe en disco.
7. **#194 [E]** ✅ `std/fs` no podía fijar la fecha de modificación (ahora `fs.set_mtime`).
8. **#195 [E]** ✅ `std/fs` no tenía `readlink` (ahora `fs.read_link`).
9. **#196 [D]** ✅ `llms.txt` listaba `std/huffman` sin decir que es solo HPACK.
10. **#197 [B]** ✅ `worker_count()`/`worker_id()` no compilaban en nativo para Windows arm64.
11. **#198 [B]** ✅ `fs.symlink` en Windows con `/` en el destino creaba un enlace que no se seguía.
12. **#199 [D]** ⚠️ `fs.chmod` es `Err` en Windows y `Stat.mode` vale 0; la doc de `chmod` ya lo dice,
    la de `Stat` no.
13. **#200 [E]** ✅ No había hora local en Windows: ni `tz` ni `std/time`.
14. **#223 [B]** (con 1.27.73) `inflate.stream_push` pierde datos en cuanto el stream llega en más de
    un trozo: las entradas grandes salen como corruptas.
15. **#224 [D]**, **#225 [D]** (con 1.27.73) la doc de `time.local_offset_ms` usa un literal que no
    compila (`3_600_000`), y `fs.read_link` en Windows devuelve `\` aunque se escribió `/`.

Lo que salió bien: `bytesbuilder` para construir registros, las fibras para comprimir en paralelo
(4,5× con 8), `tz` para la hora DOS local, `fs.seek` sobre un handle de escritura para parchear la
CRC, y `fs.is_within_real` para los symlinks plantados. Los 36 tests pasaron en nativo a la primera.
Windows destapó dos fallos de rayzip, ya corregidos: la letra de unidad entraba en los nombres de las
entradas con rutas absolutas (`C:/…`, que el propio rayzip se negaba a extraer), y los nombres CP437
de `tar.exe`/`Compress-Archive` se leían como Latin-1 (`ñ` salía `¤`).
