"""Exercise the production HTTPS helper against a local TLS server."""
import http.server
import pathlib
import ssl
import subprocess
import tempfile
import threading
import unittest


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        redirects = {"/relative": "/payload", "/downgrade": "http://localhost/", "/loop": "/loop"}
        if self.path in redirects:
            self.send_response(302)
            self.send_header("Location", redirects[self.path])
            self.end_headers()
        else:
            self.send_response(503 if self.path == "/error" else 200)
            self.end_headers()
            self.wfile.write(b"verified payload")

    def log_message(self, *_):
        pass


class HttpsDownloadTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = pathlib.Path(cls.temp.name)
        source = pathlib.Path(__file__).resolve().parents[1] / "deps/apk/app/src/main/java/com/dpejoh/specter/HttpsDownload.java"
        subprocess.run(["javac", "-d", str(cls.root), str(source)], check=True)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
            "-keyout", str(cls.root / "key.pem"), "-out", str(cls.root / "cert.pem"),
        ], check=True, capture_output=True)
        subprocess.run([
            "keytool", "-importcert", "-noprompt", "-alias", "test", "-storepass", "testpass",
            "-keystore", str(cls.root / "trust.p12"), "-file", str(cls.root / "cert.pem"),
        ], check=True, capture_output=True)
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cls.root / "cert.pem", cls.root / "key.pem")
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temp.cleanup()

    def download(self, path="/payload", *, host="localhost", trusted=True, scheme="https"):
        output = self.root / "download"
        output.write_bytes(b"stale bytes")
        command = ["java", "-cp", str(self.root)]
        if trusted:
            command += [f"-Djavax.net.ssl.trustStore={self.root / 'trust.p12'}", "-Djavax.net.ssl.trustStorePassword=testpass"]
        command += ["com.dpejoh.specter.HttpsDownload", f"{scheme}://{host}:{self.server.server_port}{path}", str(output), "Specter/test"]
        result = subprocess.run(command, capture_output=True, timeout=20)
        return result.returncode, output

    def test_trusted_certificate(self):
        status, output = self.download()
        self.assertEqual(status, 0)
        self.assertEqual(output.read_bytes(), b"verified payload")

    def test_relative_https_redirect(self):
        status, output = self.download("/relative")
        self.assertEqual(status, 0)
        self.assertEqual(output.read_bytes(), b"verified payload")

    def test_rejects_untrusted_certificate(self):
        status, output = self.download(trusted=False)
        self.assertNotEqual(status, 0)
        self.assertFalse(output.exists())

    def test_rejects_wrong_hostname(self):
        status, output = self.download(host="127.0.0.1")
        self.assertNotEqual(status, 0)
        self.assertFalse(output.exists())

    def test_rejects_http_and_redirect_downgrades(self):
        for options in [{"scheme": "http"}, {"path": "/downgrade"}, {"path": "/loop"}, {"path": "/error"}]:
            with self.subTest(options=options):
                status, output = self.download(**options)
                self.assertNotEqual(status, 0)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
