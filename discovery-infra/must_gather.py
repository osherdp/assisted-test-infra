#!/usr/bin/env python3

import subprocess
from argparse import ArgumentParser

from logger import log


def download_must_gather(kubeconfig: str, dest_dir: str):
    log.info(f"Downloading must-gather to {dest_dir}")
    command = f"oc --insecure-skip-tls-verify --kubeconfig={kubeconfig} adm must-gather --dest-dir {dest_dir} > {dest_dir}/must-gather.log"
    subprocess.run(command, shell=True)


def handle_arguments():
    parser = ArgumentParser(description="Fetch must-gather logs from a cluster")

    parser.add_argument("kubeconfig", "-c", "--kubeconfig", help="URL of remote inventory", type=str)
    parser.add_argument("dest_dir", "-d", "--dest-dir", help="Destination directory for the downloaded data", type=str)

    return parser.parse_args()


if __name__ == '__main__':
    args = handle_arguments()
    download_must_gather(kubeconfig=args.kubeconfig, dest_dir=args.dest_dir)
