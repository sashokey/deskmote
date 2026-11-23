import json
import sys

def summary(report):
    targets = [target for target in report["targets"] if target["name"] == "DeskMote.app"]
    if len(targets) != 1:
        raise ValueError("Expected exactly one DeskMote.app coverage target")
    target = targets[0]
    covered, executable = target["coveredLines"], target["executableLines"]
    if type(covered) is not int or type(executable) is not int or not 0 <= covered <= executable or executable == 0:
        raise ValueError("Invalid application coverage line counts")
    return ("## Application code coverage\n\n"
            f"DeskMote.app: {covered / executable:.2%} of instrumented lines ({covered:,}/{executable:,}).\n\n"
            "Test sources and duplicate test-target copies are excluded. Line execution does not establish behavior coverage.")


if __name__ == "__main__":
    with open(sys.argv[1]) as source:
        print(summary(json.load(source)))
