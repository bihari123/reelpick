# reelpick

a low latency system to let you do all kind of stuff with videos

# Installation

## Step 1

download the zip file from the official download page (remember to download version 0.13.0. Master is unstable right now)
[https://ziglang.org/download/]

## Step 2

Extract the zig file

## Step 3

Rename the folder containing zig to **_zig_**

```
mv ./zig-linux-x86_64-0.12.0-dev.1632+acf9de376 ./zig
```

## Step 4

move the zig folder to /usr/local

```
sudo mv zig /usr/local/
```

## Step 5

Add the $PATH to bashrc

- go to the ~/.bashrc file

```
>> sudo nano ~/.bashrc
```

- add the path to zig at the end of the file

```
export PATH=$PATH:/usr/local/zig
```

- source the ~/.bashrc

```
>> source ~/.bashrc
```

- test the installation

```
>> zig
info: Usage: zig [command] [options]

Commands:

  build            Build project from build.zig
  fetch            Copy a package into global cache and print its hash
  init-exe         Initialize a `zig build` application in the cwd
  init-lib         Initialize a `zig build` library in the cwd

  ast-check        Look for simple compile errors in any set of files
  build-exe        Create executable from source or object files
  build-lib        Create library from source or object files
  build-obj        Create object from source or object files
  fmt              Reformat Zig source into canonical form
  run              Create executable and run immediately
  test             Create and run a test build
  translate-c      Convert C code to Zig code

  ar               Use Zig as a drop-in archiver
  cc               Use Zig as a drop-in C compiler
  c++              Use Zig as a drop-in C++ compiler
  dlltool          Use Zig as a drop-in dlltool.exe
  lib              Use Zig as a drop-in lib.exe
  ranlib           Use Zig as a drop-in ranlib
  objcopy          Use Zig as a drop-in objcopy
  rc               Use Zig as a drop-in rc.exe

  env              Print lib path, std path, cache directory, and version
  help             Print this help and exit
  libc             Display native libc paths file or validate one
  targets          List available compilation targets
  version          Print version number and exit
  zen              Print Zen of Zig and exit

General Options:

  -h, --help       Print command-specific usage

error: expected command argument
```

## Install dependencies

```
sudo apt-get update && sudo apt-get install libhiredis-dev

```

## testing 
go to the /backend dir and run the following commands
```
$ zig test src/service/opensearch/opensearch_helper.zig -lc -lcurl

$ zig test src/service/ffmpeg/ffmpeg_helper.zig 

$ zig test src/service/redis/redis_helper.zig -I/usr/include -L/usr/lib -lhiredis

$ zig test src/service/sqlite/sqlite_helper.zig -I./third_party/sqlite -lc third_party/sqlite/sqlite3.c -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_ENABLE_UNLOCK_NOTIFY -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_SECURE_DELETE


```

## Build

First run the docker services. Go to each directory of the **/deployment** and run

```
$ docker compose up
```

go to the /backend and run

```
$ zig build
$ mkdir agents
$ cp ./zig-out/bin/reelpick ./agents/reelpick1
$ cd ./agents
$ ./reelpick1
```
**NOTE:** The envoy proxy can handle two backend server (port 5000 and 5050). So if you wanna see parallel chunk processing, then change the port in the backend/main.zig from 5050 to 5000 (or vice versa) and repeat the above steps (change `cp ./zig-out/bin/reelpick ./agents/reelpick1` to `cp ./zig-out/bin/reelpick ./agents/reelpick2`) and run `./reelpick2`

go to the /frontend folder (front end only support file upload for now, for join and trim, see the curl request below)

```
$ npm  run start
```

**Docker**: the backend is pushed on docker hub (docker pull bihari123/reelpick5050:latest)

## API for trimming and joining

```
curl -X POST http://localhost:5050/api/trim \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer tk_1234567890abcdef" \
  -d '{
    "fileName": "./uploads/input.mp4",
    "start_time": 30,
    "duration": 60,
    "outputFile": "output.mp4"
  }'
```

```
curl -X POST http://localhost:5000/api/video/join \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer tk_1234567890abcdef" \
  -d '{
    "parts": ["video1.mp4", "video2.mp4"],
    "outputFile": "joined_output.mp4"
  }'
```
