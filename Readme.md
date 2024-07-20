# Huggingface Hub

Command line tool and zig library to download huggingface models, datasets.


## Command line
Download the binary from  [latest github release](https://github.com/akhildevelops/wisdom/releases/latest) and run it in the terminal to download any file from huggingface repo.

To download `config.json` from the repo [THUDM/codegeex4-all-9b](https://huggingface.co/THUDM/codegeex4-all-9b) run below:
```shell

hf_hub THUDM/codegeex4-all-9b config.json

```
Response would be similar to below:
```shell
Started Downloading config.json from the repo THUDM/codegeex4-all-9b
File has been downloaded at: /home/akhil/.cache/huggingface/hub/models--THUDM--codegeex4-all-9b/snapshots/6ee90cf42fbd24807825b5ff6bed9830a5a4cfb2/config.json
```


## Library
To use it as a library in application, first install it by
```shell
zig fetch --save=hf_hub git+https://github.com/akhildevelops/wisdom
```
Add below to the application's `build.zig` file
```zig
const hf_hub_dep = b.dependency("hf_hub", .{});
exe.root_module.addImport("hf_hub", hf_hub_dep.module("hf_hub"));
```
Refer to this [example](example/hf-hub/) that imports as library

## Attention
- This is still in active development.
- Supports only Linux
