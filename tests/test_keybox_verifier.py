"""Exercise keybox validation using freshly generated, non-production keys."""
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import NameOID

ROOT = pathlib.Path(__file__).resolve().parents[1]
JAVA_SOURCE = ROOT / "deps/apk/app/src/main/java/com/dpejoh/specter/KeyboxVerifier.java"
JSON_JAR = os.environ["SPECTER_JSON_JAR"]
BC_CLASSPATH = os.environ.get("SPECTER_BC_CLASSPATH")


def certificate(subject, issuer, public_key, signing_key, serial, start, end, ca):
    return (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer)
            .public_key(public_key).serial_number(serial).not_valid_before(start)
            .not_valid_after(end).add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
            .sign(signing_key, hashes.SHA256()))


class KeyboxVerifierTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.path = pathlib.Path(cls.temp.name)
        subprocess.run(["javac", "-cp", JSON_JAR, "-d", str(cls.path), str(JAVA_SOURCE)], check=True)
        if BC_CLASSPATH:
            subprocess.run(["javac", "-cp", BC_CLASSPATH, "-d", str(cls.path),
                            str(ROOT / "tests/PemKeyPairCheck.java")], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        self.now = now
        self.ca_key = ec.generate_private_key(ec.SECP256R1())
        self.leaf_key = ec.generate_private_key(ec.SECP256R1())
        self.ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Synthetic root")])
        self.leaf_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Synthetic leaf")])
        self.ca = certificate(self.ca_name, self.ca_name, self.ca_key.public_key(), self.ca_key, 42,
                              now - dt.timedelta(days=1), now + dt.timedelta(days=30), True)
        self.leaf = certificate(self.leaf_name, self.ca_name, self.leaf_key.public_key(), self.ca_key, 43,
                                now - dt.timedelta(days=1), now + dt.timedelta(days=7), False)
        self.write_roots([self.ca])
        self.write_status({})

    def write_roots(self, certs):
        data = [c.public_bytes(serialization.Encoding.PEM).decode() for c in certs]
        (self.path / "roots.json").write_text(json.dumps(data))

    def write_status(self, entries):
        (self.path / "status.json").write_text(json.dumps({"entries": entries}))

    def write_keybox(self, *, key=None, leaf=None, root=None, algorithm="ecdsa", declared_count=2,
                     key_format=serialization.PrivateFormat.TraditionalOpenSSL):
        key = key or self.leaf_key
        leaf = leaf or self.leaf
        root = root or self.ca
        private = key.private_bytes(serialization.Encoding.PEM, key_format,
                                    serialization.NoEncryption()).decode()
        certs = "".join("<Certificate format='pem'>" + c.public_bytes(serialization.Encoding.PEM).decode() +
                        "</Certificate>" for c in (leaf, root))
        xml = ("<AndroidAttestation><Keybox><Key algorithm='" + algorithm + "'><PrivateKey>" + private +
               "</PrivateKey><CertificateChain><NumberOfCertificates>" + str(declared_count) +
               "</NumberOfCertificates>" + certs + "</CertificateChain></Key></Keybox></AndroidAttestation>")
        (self.path / "keybox.xml").write_text(xml)

    def run_helper(self, mode="verify"):
        args = ["java", "-cp", os.pathsep.join([str(self.path), JSON_JAR]),
                "com.dpejoh.specter.KeyboxVerifier", mode, str(self.path / "keybox.xml")]
        if mode == "verify":
            args += [str(self.path / "roots.json"), str(self.path / "status.json")]
        elif mode == "normalize":
            args += [str(self.path / "normalized.xml")]
        return subprocess.run(args, capture_output=True, text=True, timeout=15)

    def test_valid_ec_and_expiry(self):
        self.write_keybox()
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(int(result.stdout), int(self.leaf.not_valid_after_utc.timestamp()))
        self.assertEqual(self.run_helper("expiry").stdout, result.stdout)
        self.assertEqual(self.run_helper("serial").stdout.strip(), "2b")
        self.assertEqual(self.run_helper("algorithms").stdout.strip(), "ec")
        self.assertEqual(self.run_helper("rkp").stdout.strip(), "0")

    def test_valid_rsa(self):
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        leaf = certificate(self.leaf_name, self.ca_name, key.public_key(), self.ca_key, 44,
                           self.now - dt.timedelta(days=1), self.now + dt.timedelta(days=3), False)
        self.write_keybox(key=key, leaf=leaf, algorithm="rsa")
        self.assertEqual(self.run_helper().returncode, 0)

    def test_pkcs8_converts_to_backend_compatible_keys(self):
        for key, algorithm in [(self.leaf_key, "ecdsa"),
                               (rsa.generate_private_key(public_exponent=65537, key_size=2048), "rsa")]:
            with self.subTest(algorithm=algorithm):
                leaf = certificate(self.leaf_name, self.ca_name, key.public_key(), self.ca_key, 44,
                                   self.now - dt.timedelta(days=1), self.now + dt.timedelta(days=3), False)
                self.write_keybox(key=key, leaf=leaf, algorithm=algorithm, key_format=serialization.PrivateFormat.PKCS8)
                original = (self.path / "keybox.xml").read_text()
                self.assertEqual(self.run_helper().returncode, 0)
                result = self.run_helper("normalize")
                self.assertEqual(result.returncode, 0, result.stderr)
                normalized = (self.path / "normalized.xml").read_text()
                label = "EC PRIVATE KEY" if algorithm == "ecdsa" else "RSA PRIVATE KEY"
                new_pem = re.search(r"-----BEGIN " + label + r"-----.*?-----END " + label + r"-----", normalized, re.S).group()
                old_pem = re.search(r"-----BEGIN PRIVATE KEY-----.*?-----END PRIVATE KEY-----", original, re.S).group()
                self.assertEqual(normalized.replace(new_pem, old_pem), original)
                parsed = serialization.load_pem_private_key(new_pem.encode(), None)
                self.assertEqual(parsed.private_numbers(), key.private_numbers())
                if BC_CLASSPATH:
                    pem_path = self.path / "synthetic-private.pem"
                    pem_path.write_text(new_pem)
                    subprocess.run(["java", "-cp", os.pathsep.join([str(self.path), BC_CLASSPATH]),
                                    "PemKeyPairCheck", str(pem_path)], check=True, capture_output=True)
                (self.path / "keybox.xml").write_text(normalized)
                self.assertEqual(self.run_helper().returncode, 0)
                self.assertEqual(self.run_helper("normalize").returncode, 0)
                self.assertEqual((self.path / "normalized.xml").read_text(), normalized)

    def test_wrong_private_key_and_algorithm(self):
        self.write_keybox(key=ec.generate_private_key(ec.SECP256R1()))
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.write_keybox(algorithm="rsa")
        self.assertNotEqual(self.run_helper().returncode, 0)

    def test_normalizes_multiple_keys_without_changing_certificates(self):
        self.write_keybox(key_format=serialization.PrivateFormat.PKCS8)
        ec_key = re.search(r"<Key\b.*?</Key>", (self.path / "keybox.xml").read_text(), re.S).group()
        rsa_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        rsa_leaf = certificate(self.leaf_name, self.ca_name, rsa_key.public_key(), self.ca_key, 44,
                               self.now - dt.timedelta(days=1), self.now + dt.timedelta(days=3), False)
        self.write_keybox(key=rsa_key, leaf=rsa_leaf, algorithm="rsa", key_format=serialization.PrivateFormat.PKCS8)
        rsa_xml = (self.path / "keybox.xml").read_text()
        combined = rsa_xml.replace("<Keybox>", "<Keybox>" + ec_key, 1)
        (self.path / "keybox.xml").write_text(combined)
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.run_helper("normalize").returncode, 0)
        normalized = (self.path / "normalized.xml").read_text()
        self.assertIn("BEGIN EC PRIVATE KEY", normalized)
        self.assertIn("BEGIN RSA PRIVATE KEY", normalized)
        self.assertEqual(re.findall(r"<Certificate .*?</Certificate>", combined, re.S),
                         re.findall(r"<Certificate .*?</Certificate>", normalized, re.S))
        (self.path / "keybox.xml").write_text(normalized)
        self.assertEqual(self.run_helper().returncode, 0)

    def test_revoked_leaf_or_root_hex_and_decimal(self):
        self.write_keybox()
        for serial in ("43", "2b", "42", "2a"):
            self.write_status({serial: {"status": "REVOKED"}})
            self.assertNotEqual(self.run_helper().returncode, 0, serial)

    def test_invalid_chain_expiry_and_trust(self):
        for start, end in [(self.now - dt.timedelta(days=2), self.now - dt.timedelta(days=1)),
                           (self.now + dt.timedelta(days=1), self.now + dt.timedelta(days=2))]:
            leaf = certificate(self.leaf_name, self.ca_name, self.leaf_key.public_key(), self.ca_key, 43, start, end, False)
            self.write_keybox(leaf=leaf)
            self.assertNotEqual(self.run_helper().returncode, 0)
        other_key = ec.generate_private_key(ec.SECP256R1())
        bad_leaf = certificate(self.leaf_name, self.ca_name, self.leaf_key.public_key(), other_key, 43,
                               self.now - dt.timedelta(days=1), self.now + dt.timedelta(days=1), False)
        self.write_keybox(leaf=bad_leaf)
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.write_keybox()
        self.write_roots([])
        self.assertNotEqual(self.run_helper().returncode, 0)

    def test_invalid_status_count_and_xxe_fail_closed(self):
        self.write_keybox()
        (self.path / "status.json").write_text("{}")
        self.assertNotEqual(self.run_helper().returncode, 0)
        self.write_status({})
        self.write_keybox(declared_count=3)
        self.assertNotEqual(self.run_helper().returncode, 0)
        (self.path / "keybox.xml").write_text('<!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><foo>&xxe;</foo>')
        self.assertNotEqual(self.run_helper().returncode, 0)


if __name__ == "__main__":
    unittest.main()
