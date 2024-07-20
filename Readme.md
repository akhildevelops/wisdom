# Huggingface Hub

Command line tool and zig library to download huggingface models, datasets.


## Command line
Download the binary from github releases and run it in the terminal to download any file from huggingface repo.

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



## Attention
- This is still in active development.
- Supports only Linux