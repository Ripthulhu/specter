import java.io.FileReader;
import java.security.KeyPair;
import java.security.Signature;
import org.bouncycastle.openssl.PEMKeyPair;
import org.bouncycastle.openssl.PEMParser;
import org.bouncycastle.openssl.jcajce.JcaPEMKeyConverter;

public final class PemKeyPairCheck {
    public static void main(String[] args) throws Exception {
        try (PEMParser parser = new PEMParser(new FileReader(args[0]))) {
            Object parsed = parser.readObject();
            if (!(parsed instanceof PEMKeyPair)) throw new IllegalArgumentException("Expected PEMKeyPair");
            KeyPair key = new JcaPEMKeyConverter().getKeyPair((PEMKeyPair) parsed);
            Signature signature = Signature.getInstance(key.getPrivate().getAlgorithm().equals("EC")
                    ? "SHA256withECDSA" : "SHA256withRSA");
            byte[] message = {1, 2, 3};
            signature.initSign(key.getPrivate());
            signature.update(message);
            byte[] signed = signature.sign();
            signature.initVerify(key.getPublic());
            signature.update(message);
            if (!signature.verify(signed)) throw new IllegalArgumentException("Key pair mismatch");
        }
    }
}
