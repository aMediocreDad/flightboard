"""review-state.py — join PR heads with the review ledger.

    python3 review-state.py <heads.tsv> <reviews.tsv>

heads.tsv rows are `repo  num  role  head-sha` (role is mine or requested);
reviews.tsv is the ledger record-review.sh appends to, possibly missing.
Prints one REVIEW_STATE row per PR with the newest review of that PR:

    unreviewed          no review on record
    clean               reviewed at the current head, nothing found
    findings:N          reviewed at the current head, N findings
    stale:<verdict>     the last review was of an older head
    head-unknown        GitHub did not return the PR, so the head is unknown
"""
import sys


def main():
    heads_path, ledger_path = sys.argv[1], sys.argv[2]
    latest = {}
    try:
        with open(ledger_path) as f:
            for line in f:
                cols = line.rstrip("\n").split("\t")
                if len(cols) < 6:
                    continue
                at, repo, num, sha, verdict, count = cols[:6]
                latest[(repo, num)] = (at, sha, verdict, count)  # file order is time order
    except FileNotFoundError:
        pass

    print("### REVIEW_STATE\trepo\tnum\trole\thead\tstatus\treviewed")
    for line in open(heads_path):
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 4:
            continue
        repo, num, role, head = cols[:4]
        rec = latest.get((repo, num))
        if head == "-":
            status, when = "head-unknown", "-"  # GitHub did not return the PR
        elif rec is None:
            status, when = "unreviewed", "-"
        else:
            at, sha, verdict, count = rec
            label = "clean" if verdict == "clean" else f"findings:{count}"
            status = label if sha == head else f"stale:{label}"
            when = f"{at} @{sha[:7]}"
        print("\t".join([repo, num, role, head[:7], status, when]))


if __name__ == "__main__":
    main()
