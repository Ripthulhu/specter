package com.dpejoh.specter;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Date;
import java.util.List;
import javax.xml.parsers.DocumentBuilderFactory;
import org.json.JSONArray;
import org.json.JSONObject;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

/** Checks local keybox material without logging private keys or certificate serials. */
public final class KeyboxVerifier {
    private static final int MAX_XML_BYTES = 1024 * 1024;
    private static String firstSerial;
    private static boolean hasProvisioningInfo;
    private static String algorithms;

    private static byte[] pem(String text, String label) {
        String body = text.replace("-----BEGIN " + label + "-----", "")
                .replace("-----END " + label + "-----", "").replaceAll("\\s", "");
        return Base64.getDecoder().decode(body);
    }

    private static byte[] der(int tag, byte[] data) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(tag);
        int n = data.length;
        if (n < 128) out.write(n);
        else {
            int bytes = 0;
            for (int v = n; v != 0; v >>>= 8) bytes++;
            out.write(128 | bytes);
            for (int i = bytes - 1; i >= 0; i--) out.write(n >>> (8 * i));
        }
        out.write(data);
        return out.toByteArray();
    }

    private static byte[] concat(byte[]... values) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (byte[] value : values) out.write(value);
        return out.toByteArray();
    }

    private static int contentOffset(byte[] data, int start) {
        int len = data[start + 1] & 255;
        return start + 2 + (len >= 128 ? len - 128 : 0);
    }

    private static int endOffset(byte[] data, int start) {
        int len = data[start + 1] & 255;
        int off = start + 2;
        if (len >= 128) {
            int count = len - 128;
            if (count < 1 || count > 4) throw new IllegalArgumentException();
            len = 0;
            for (int i = 0; i < count; i++) len = (len << 8) | (data[off++] & 255);
        }
        int end = off + len;
        if (end > data.length || end < off) throw new IllegalArgumentException();
        return end;
    }

    private static PrivateKey privateKey(String text, X509Certificate leaf) throws Exception {
        String algorithm = leaf.getPublicKey().getAlgorithm();
        byte[] encoded;
        if (text.contains("-----BEGIN PRIVATE KEY-----")) encoded = pem(text, "PRIVATE KEY");
        else {
            String label = algorithm.equals("EC") ? "EC PRIVATE KEY" : "RSA PRIVATE KEY";
            byte[] publicDer = leaf.getPublicKey().getEncoded();
            int start = contentOffset(publicDer, 0), end = endOffset(publicDer, start);
            byte[] alg = java.util.Arrays.copyOfRange(publicDer, start, end);
            encoded = der(0x30, concat(new byte[]{2, 1, 0}, alg, der(4, pem(text, label))));
        }
        return KeyFactory.getInstance(algorithm).generatePrivate(new PKCS8EncodedKeySpec(encoded));
    }

    private static X509Certificate certificate(String pem) throws Exception {
        return (X509Certificate) CertificateFactory.getInstance("X.509").generateCertificate(
                new ByteArrayInputStream(pem(pem, "CERTIFICATE")));
    }

    private static String text(Element el, String name) {
        NodeList nodes = el.getElementsByTagName(name);
        if (nodes.getLength() != 1) throw new IllegalArgumentException("Missing or duplicate " + name);
        return nodes.item(0).getTextContent();
    }

    private static long inspect(String path, String rootsPath, String statusPath) throws Exception {
        long size = Files.size(Paths.get(path));
        if (size == 0 || size > MAX_XML_BYTES) throw new IllegalArgumentException("Invalid size");
        byte[] xml = Files.readAllBytes(Paths.get(path));
        if (xml.length == 0 || xml.length > MAX_XML_BYTES) throw new IllegalArgumentException("Invalid size");
        for (byte b : xml) if (b == 0) throw new IllegalArgumentException("Invalid encoding");
        // Android's XML parser does not support the usual disallow-doctype feature.
        if (new String(xml, StandardCharsets.US_ASCII).contains("<!DOCTYPE"))
            throw new IllegalArgumentException("DOCTYPE is not allowed");
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        NodeList keys = factory.newDocumentBuilder().parse(new ByteArrayInputStream(xml)).getElementsByTagName("Key");
        if (keys.getLength() < 1 || keys.getLength() > 2) throw new IllegalArgumentException("Invalid keys");
        boolean verify = rootsPath != null;
        List<X509Certificate> roots = new ArrayList<>();
        JSONObject revoked = null;
        if (verify) {
            if (Files.size(Paths.get(rootsPath)) > MAX_XML_BYTES || Files.size(Paths.get(statusPath)) > 4 * MAX_XML_BYTES)
                throw new IllegalArgumentException("Verification data too large");
            JSONArray trusted = new JSONArray(new String(Files.readAllBytes(Paths.get(rootsPath)), StandardCharsets.UTF_8));
            for (int i = 0; i < trusted.length(); i++) roots.add(certificate(trusted.getString(i)));
            if (roots.isEmpty()) throw new IllegalArgumentException("Empty trust roots");
            revoked = new JSONObject(new String(Files.readAllBytes(Paths.get(statusPath)), StandardCharsets.UTF_8)).getJSONObject("entries");
        }
        long expiry = Long.MAX_VALUE;
        boolean hasEc = false, hasRsa = false;
        for (int k = 0; k < keys.getLength(); k++) {
            Element key = (Element) keys.item(k);
            String declared = key.getAttribute("algorithm");
            if (declared.equals("ecdsa") && !hasEc) hasEc = true;
            else if (declared.equals("rsa") && !hasRsa) hasRsa = true;
            else throw new IllegalArgumentException("Invalid key algorithm");
            NodeList certs = key.getElementsByTagName("Certificate");
            if (certs.getLength() < 2 || certs.getLength() > 8 ||
                    Integer.parseInt(text(key, "NumberOfCertificates").trim()) != certs.getLength())
                throw new IllegalArgumentException("Invalid certificate chain");
            List<X509Certificate> chain = new ArrayList<>();
            for (int i = 0; i < certs.getLength(); i++) {
                X509Certificate cert = certificate(certs.item(i).getTextContent());
                if (k == 0 && i == 0) firstSerial = cert.getSerialNumber().toString(16);
                if (cert.getExtensionValue("1.3.6.1.4.1.11129.2.1.30") != null) hasProvisioningInfo = true;
                expiry = Math.min(expiry, cert.getNotAfter().getTime() / 1000);
                if (verify) {
                    cert.checkValidity(new Date());
                    String hex = cert.getSerialNumber().toString(16);
                    if (revoked.has(hex) || revoked.has(cert.getSerialNumber().toString()))
                        throw new IllegalArgumentException("Revoked certificate");
                }
                chain.add(cert);
            }
            if (!verify) continue;
            for (int i = 0; i + 1 < chain.size(); i++) {
                X509Certificate issuer = chain.get(i + 1);
                boolean[] usage = issuer.getKeyUsage();
                if (issuer.getBasicConstraints() < 0 || (usage != null && (usage.length <= 5 || !usage[5])))
                    throw new IllegalArgumentException("Issuer is not a CA");
                if (!chain.get(i).getIssuerX500Principal().equals(chain.get(i + 1).getSubjectX500Principal()))
                    throw new IllegalArgumentException("Invalid issuer");
                chain.get(i).verify(chain.get(i + 1).getPublicKey());
            }
            X509Certificate root = chain.get(chain.size() - 1);
            boolean trusted = false;
            for (X509Certificate known : roots) if (known.equals(root)) trusted = true;
            if (!trusted) throw new IllegalArgumentException("Untrusted root");
            root.verify(root.getPublicKey());
            X509Certificate leaf = chain.get(0);
            String algorithm = leaf.getPublicKey().getAlgorithm();
            if (!(declared.equals("ecdsa") && algorithm.equals("EC")) &&
                !(declared.equals("rsa") && algorithm.equals("RSA")))
                throw new IllegalArgumentException("Algorithm mismatch");
            Signature signature = Signature.getInstance(algorithm.equals("EC") ? "SHA256withECDSA" : "SHA256withRSA");
            byte[] challenge = "Specter keybox validation".getBytes(StandardCharsets.US_ASCII);
            signature.initSign(privateKey(text(key, "PrivateKey"), leaf));
            signature.update(challenge);
            byte[] signed = signature.sign();
            signature.initVerify(leaf.getPublicKey());
            signature.update(challenge);
            if (!signature.verify(signed)) throw new IllegalArgumentException("Mismatched private key");
        }
        algorithms = (hasEc ? "ec" : "") + (hasRsa ? "rsa" : "");
        return expiry;
    }

    public static void main(String[] args) {
        try {
            if (!(args.length == 2 && (args[0].equals("expiry") || args[0].equals("serial") || args[0].equals("rkp") || args[0].equals("algorithms"))) &&
                !(args.length == 4 && args[0].equals("verify"))) throw new IllegalArgumentException("Invalid arguments");
            long expiry = inspect(args[1], args.length == 4 ? args[2] : null, args.length == 4 ? args[3] : null);
            System.out.println(args[0].equals("serial") ? firstSerial : args[0].equals("algorithms") ? algorithms :
                    args[0].equals("rkp") ? (hasProvisioningInfo ? "1" : "0") : Long.toString(expiry));
        } catch (Exception ex) {
            System.err.println("Keybox validation failed: " + ex.getClass().getSimpleName());
            System.exit(1);
        }
    }
}
