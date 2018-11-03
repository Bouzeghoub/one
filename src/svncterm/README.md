# svncterm for OpenNebula's LXD drivers

Forked from [dealfonso@github](https://github.com/dealfonso/svncterm)

## Build instructions

### Ubuntu

```bash
DEBIAN_FRONTEND=noninteractive
apt-get install -y lintian make build-essential zlib1g-dev console-data quilt libgnutls28-dev libjpeg-dev libvncserver-dev
make
```

Build debian distro package

```bash
make deb
```