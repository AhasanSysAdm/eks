"""Update Git-tracked image references after a successful ECR publication."""
import argparse
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--cluster", default="academy-eks-demo")
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"\d{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com", args.registry):
        parser.error("Expected a private ECR registry hostname, without a scheme or path")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", args.cluster):
        parser.error("Invalid lab cluster name")
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", args.tag):
        parser.error("Invalid image tag")
    root = Path(__file__).resolve().parents[1]
    updates = []
    for relative, image in (
        ("hpa/demo.yaml", "php"),
        ("hpa/load.yaml", "busybox"),
        ("hpa/vpa-demo.yaml", "busybox"),
    ):
        path = root / relative
        text = path.read_text(encoding="utf-8")
        text, count = re.subn(
            r"(?m)^(\s+image:)\s+\S+\s*$",
            rf"\1 {args.registry}/{args.cluster}/{image}:{args.tag}",
            text,
        )
        if count != 1:
            raise ValueError(f"{path}: expected exactly one container image, found {count}")
        updates.append((path, text))
    path = root / "argo" / "chart" / "values.yaml"
    text = path.read_text(encoding="utf-8")
    for key, value in (
        ("repository", f"{args.registry}/{args.cluster}/web"),
        ("tag", args.tag),
    ):
        text, count = re.subn(
            rf'(?m)^  {key}:.*$', f'  {key}: "{value}"', text
        )
        if count != 1:
            raise ValueError(f"{path}: expected exactly one image {key}")
    updates.append((path, text))
    for path, text in updates:
        path.write_text(text, encoding="utf-8", newline="\n")
        print(f"Updated {path.relative_to(root)}")


if __name__ == "__main__":
    main()
