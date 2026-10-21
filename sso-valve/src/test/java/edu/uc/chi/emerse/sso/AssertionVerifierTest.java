package edu.uc.chi.emerse.sso;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.Map;

import org.apache.tomcat.util.json.JSONParser;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class AssertionVerifierTest
{
	static final String ISS = "https://chi-tools.uc.edu/auth/";
	static final String AUD = "chi-tools.uc.edu";
	static final long NOW = 1_800_000_000L;
	static final Base64.Encoder B64 = Base64.getUrlEncoder().withoutPadding();

	KeyPair pair;
	AssertionVerifier verifier;

	@BeforeEach
	void setUp() throws Exception
	{
		pair = keyPair();
		verifier = verifierFor(jwks("k1", (ECPublicKey) pair.getPublic()));
	}

	@Test
	void acceptsWhatChiAuthSends() throws Exception
	{
		assertEquals("iretonrt", verifier.verify(token(pair, header("k1"), claims("iretonrt", ISS, "\"" + AUD + "\"", NOW + 120))));
	}

	/** A token minted by CHI Authentication's own signer (jose), not by this test's code. */
	@Test
	void acceptsRealChiAuthToken() throws Exception
	{
		try (var in = getClass().getResourceAsStream("/chi-auth-fixture.json"))
		{
			Map<String, Object> fixture = new JSONParser(new String(in.readAllBytes(), StandardCharsets.UTF_8)).parseObject();
			var jwks = (String) fixture.get("jwks");
			var now = ((Number) fixture.get("now")).longValue();
			var clock = Clock.fixed(Instant.ofEpochSecond(now), ZoneOffset.UTC);
			var real = new AssertionVerifier(AssertionVerifier.parseJwks(jwks), ISS, AUD, 30, clock);
			assertEquals("iretonrt", real.verify((String) fixture.get("token")));
		}
	}

	@Test
	void acceptsAudienceArray() throws Exception
	{
		assertEquals("u", verifier.verify(token(pair, header("k1"), claims("u", ISS, "[\"x\",\"" + AUD + "\"]", NOW + 120))));
	}

	@Test
	void allowsClockSkew() throws Exception
	{
		assertEquals("u", verifier.verify(token(pair, header("k1"), claims("u", ISS, q(AUD), NOW - 20))));
	}

	@Test
	void rejectsExpired()
	{
		assertRejected(token(pair, header("k1"), claims("u", ISS, q(AUD), NOW - 31)), "expired");
	}

	@Test
	void rejectsWrongAudience()
	{
		assertRejected(token(pair, header("k1"), claims("u", ISS, q("chi.uc.edu"), NOW + 120)), "wrong audience");
	}

	@Test
	void rejectsWrongIssuer()
	{
		assertRejected(token(pair, header("k1"), claims("u", "https://chi.uc.edu/auth/", q(AUD), NOW + 120)), "wrong issuer");
	}

	@Test
	void rejectsTamperedPayload()
	{
		var good = token(pair, header("k1"), claims("someone", ISS, q(AUD), NOW + 120)).split("\\.");
		var forged = B64.encodeToString(claims("admin", ISS, q(AUD), NOW + 120).getBytes(StandardCharsets.UTF_8));
		assertRejected(good[0] + "." + forged + "." + good[2], "bad signature");
	}

	@Test
	void rejectsOtherKey() throws Exception
	{
		assertRejected(token(keyPair(), header("k1"), claims("u", ISS, q(AUD), NOW + 120)), "bad signature");
	}

	@Test
	void rejectsUnknownKid()
	{
		assertRejected(token(pair, header("k2"), claims("u", ISS, q(AUD), NOW + 120)), "unknown kid");
	}

	@Test
	void rejectsAlgNone()
	{
		var h = B64.encodeToString("{\"alg\":\"none\",\"kid\":\"k1\"}".getBytes(StandardCharsets.UTF_8));
		var p = B64.encodeToString(claims("u", ISS, q(AUD), NOW + 120).getBytes(StandardCharsets.UTF_8));
		assertRejected(h + "." + p + ".", "alg is not ES256");
	}

	@Test
	void rejectsMissingSubject()
	{
		var c = "{\"iss\":" + q(ISS) + ",\"aud\":" + q(AUD) + ",\"exp\":" + (NOW + 120) + "}";
		assertRejected(token(pair, header("k1"), c), "no subject");
	}

	@Test
	void rejectsMissingExp()
	{
		var c = "{\"sub\":\"u\",\"iss\":" + q(ISS) + ",\"aud\":" + q(AUD) + "}";
		assertRejected(token(pair, header("k1"), c), "no exp");
	}

	@Test
	void rejectsGarbage()
	{
		assertRejected("not-a-jwt", "not a compact JWS");
		assertRejected("a!.b.c", "header is not base64url");
		assertRejected(B64.encodeToString("not json".getBytes(StandardCharsets.UTF_8)) + ".b.c", "header is not a JSON object");
	}

	@Test
	void jwksSkipsKeysThatArentP256Signing() throws Exception
	{
		var pub = (ECPublicKey) pair.getPublic();
		var json = "{\"keys\":[" +
			"{\"kty\":\"RSA\",\"kid\":\"r\",\"n\":\"AQAB\",\"e\":\"AQAB\"}," +
			"{\"kty\":\"EC\",\"crv\":\"P-256\",\"kid\":\"enc\",\"use\":\"enc\",\"x\":" + q(coord(pub.getW().getAffineX())) + ",\"y\":" + q(coord(pub.getW().getAffineY())) + "}," +
			jwk("k1", pub) + "]}";
		var keys = AssertionVerifier.parseJwks(json);
		assertEquals(1, keys.size());
		assertTrue(keys.containsKey("k1"));
	}

	@Test
	void jwksRejectsPointOffCurve()
	{
		var json = "{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"kid\":\"bad\",\"x\":" + q(coord(BigInteger.ONE)) + ",\"y\":" + q(coord(BigInteger.TWO)) + "}]}";
		assertThrows(GeneralSecurityException.class, () -> AssertionVerifier.parseJwks(json));
	}

	void assertRejected(String token, String reason)
	{
		var e = assertThrows(InvalidAssertionException.class, () -> verifier.verify(token));
		assertEquals(reason, e.getMessage());
	}

	static AssertionVerifier verifierFor(String jwks) throws GeneralSecurityException
	{
		var clock = Clock.fixed(Instant.ofEpochSecond(NOW), ZoneOffset.UTC);
		return new AssertionVerifier(AssertionVerifier.parseJwks(jwks), ISS, AUD, 30, clock);
	}

	static KeyPair keyPair() throws GeneralSecurityException
	{
		var gen = KeyPairGenerator.getInstance("EC");
		gen.initialize(new ECGenParameterSpec("secp256r1"));
		return gen.generateKeyPair();
	}

	static String header(String kid)
	{
		return "{\"alg\":\"ES256\",\"kid\":" + q(kid) + ",\"typ\":\"JWT\"}";
	}

	/** The claim set lib/sso.js signs. */
	static String claims(String sub, String iss, String audJson, long exp)
	{
		return "{\"email\":\"" + sub + "@ucmail.uc.edu\",\"given_name\":\"Rob\",\"family_name\":\"Nguyễn\"," +
			"\"iss\":" + q(iss) + ",\"aud\":" + audJson + ",\"sub\":" + q(sub) + ",\"iat\":" + (exp - 120) + ",\"exp\":" + exp + "}";
	}

	static String token(KeyPair pair, String header, String claims)
	{
		try
		{
			var input = B64.encodeToString(header.getBytes(StandardCharsets.UTF_8)) + "." + B64.encodeToString(claims.getBytes(StandardCharsets.UTF_8));
			var sig = Signature.getInstance("SHA256withECDSAinP1363Format");
			sig.initSign(pair.getPrivate());
			sig.update(input.getBytes(StandardCharsets.US_ASCII));
			return input + "." + B64.encodeToString(sig.sign());
		}
		catch (GeneralSecurityException e)
		{
			throw new AssertionError(e);
		}
	}

	static String jwks(String kid, ECPublicKey pub)
	{
		return "{\"keys\":[" + jwk(kid, pub) + "]}";
	}

	static String jwk(String kid, ECPublicKey pub)
	{
		return "{\"kty\":\"EC\",\"crv\":\"P-256\",\"alg\":\"ES256\",\"use\":\"sig\",\"kid\":" + q(kid) +
			",\"x\":" + q(coord(pub.getW().getAffineX())) + ",\"y\":" + q(coord(pub.getW().getAffineY())) + "}";
	}

	static String coord(BigInteger n)
	{
		var raw = n.toByteArray();
		var fixed = new byte[32];
		var len = Math.min(raw.length, 32);
		System.arraycopy(raw, raw.length - len, fixed, 32 - len, len);
		return B64.encodeToString(fixed);
	}

	static String q(String s)
	{
		return "\"" + s + "\"";
	}
}
