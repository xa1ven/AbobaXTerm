@testable import AXTerminal
import Foundation
import Testing

@Suite struct PasteSanitizerTests {
    func fixed(_ text: String) -> String { PasteSanitizer.sanitize(text).text }

    @Test func quotes() {
        #expect(fixed("echo «a» “b” „c” ‘d’") == "echo \"a\" \"b\" \"c\" 'd'")
    }

    @Test func plainTextIsUntouched() {
        let text = "kubectl get pods -n kube-system --watch | grep -v 'Running' # ok\n"
        let result = PasteSanitizer.sanitize(text)
        #expect(result.text == text)
        #expect(!result.isChanged)
        #expect(result.unresolvedRanges.isEmpty)
    }

    @Test func dashBeforeAWordIsALongOption() {
        #expect(fixed("kubectl get pods —all-namespaces –watch") == "kubectl get pods --all-namespaces --watch")
        #expect(fixed("—help") == "--help")
    }

    @Test func dashAloneOnALineIsADocumentSeparator() {
        #expect(fixed("a: 1\n—\nb: 2\n") == "a: 1\n---\nb: 2\n")
        #expect(fixed("a: 1\n—-\nb: 2") == "a: 1\n---\nb: 2")
        #expect(fixed("  ——  ") == "  ----  ")
        #expect(fixed("---") == "---")
    }

    @Test func otherDashesAreLeftAndReported() {
        let result = PasteSanitizer.sanitize("echo a — b")
        #expect(result.text == "echo a — b")
        #expect(!result.isChanged)
        #expect(result.unresolvedRanges == [NSRange(location: 7, length: 1)])
    }

    @Test func spacesEllipsisAndInvisibleCharacters() {
        let result = PasteSanitizer.sanitize("ls\u{00A0}-la\u{200B} …\u{FEFF}")
        #expect(result.text == "ls -la ...")
        #expect(result.removedCount == 2)
    }

    @Test func rangesPointAtTheReplacements() {
        let result = PasteSanitizer.sanitize("😀 «x» —y")
        let text = result.text as NSString
        #expect(result.text == "😀 \"x\" --y")
        #expect(result.fixedRanges.map { text.substring(with: $0) } == ["\"", "\"", "--"])
    }

    @Test func lineEndingsSurvive() {
        #expect(fixed("«a»\r\n«b»\r\n") == "\"a\"\r\n\"b\"\r\n")
    }

    /// A manifest as Telegram shows it after "improving" the message.
    @Test func telegramManifest() {
        let pasted = """
        cat > /root/demo-eso-cluster.yaml <<‘EOF’
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRole
        rules:
        - apiGroups: [«external-secrets.io»]
          resources: [«clustersecretstores», «clusterexternalsecrets»]
          verbs: [«get», «list»]
        —
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        subjects:
        - kind: User
          name: demo@example.com
        EOF
        kubectl apply -f /root/demo-eso-cluster.yaml
        """
        let expected = """
        cat > /root/demo-eso-cluster.yaml <<'EOF'
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRole
        rules:
        - apiGroups: ["external-secrets.io"]
          resources: ["clustersecretstores", "clusterexternalsecrets"]
          verbs: ["get", "list"]
        ---
        apiVersion: rbac.authorization.k8s.io/v1
        kind: ClusterRoleBinding
        subjects:
        - kind: User
          name: demo@example.com
        EOF
        kubectl apply -f /root/demo-eso-cluster.yaml
        """
        let result = PasteSanitizer.sanitize(pasted)
        #expect(result.text == expected)
        #expect(result.unresolvedRanges.isEmpty)
    }
}

@Suite struct PastePolicyTests {
    func decide(_ text: String, _ settings: PasteSettings = PasteSettings(), alt: Bool = false) -> PasteDecision {
        PastePolicy.decide(text: text, settings: settings, isAlternateScreen: alt)
    }

    @Test func plainSingleLineGoesStraightThrough() {
        #expect(decide("ls -la") == .passThrough)
        #expect(decide("") == .passThrough)
    }

    @Test func severalLinesAreReviewed() {
        #expect(decide("a\nb") == .review(PasteReview(original: "a\nb")))
        // One line that ends with a line break would run at once too.
        #expect(decide("reboot\n") == .review(PasteReview(original: "reboot\n")))
        #expect(decide("a\nb", PasteSettings(confirmMultiline: false)) == .passThrough)
    }

    @Test func fullScreenProgramsGetSeveralLinesAtOnce() {
        #expect(decide("a\nb", alt: true) == .passThrough)
    }

    @Test func typographyIsReviewedEvenOnOneLine() {
        guard case .review(let review) = decide("echo «a»", alt: true) else {
            Issue.record("expected a review")
            return
        }
        #expect(review.sanitized?.text == "echo \"a\"")
        #expect(!review.isMultiline)
    }

    @Test func automaticModeFixesSilently() {
        let auto = PasteSettings(confirmMultiline: true, typography: .automatic)
        #expect(decide("echo «a»", auto) == .send("echo \"a\""))
        #expect(decide("echo a", auto) == .passThrough)
        guard case .review(let review) = decide("echo «a»\nls", auto) else {
            Issue.record("expected a review")
            return
        }
        #expect(review.sanitized?.text == "echo \"a\"\nls")
    }

    @Test func offLeavesTypographyAlone() {
        let off = PasteSettings(confirmMultiline: true, typography: .off)
        #expect(decide("echo «a»", off) == .passThrough)
        #expect(decide("echo «a»\nls", off) == .review(PasteReview(original: "echo «a»\nls")))
    }

    @Test func lineCount() {
        #expect(PastePolicy.lineCount("a") == 1)
        #expect(PastePolicy.lineCount("a\nb\n") == 2)
        #expect(PastePolicy.lineCount("a\r\nb\r\nc") == 3)
    }
}
