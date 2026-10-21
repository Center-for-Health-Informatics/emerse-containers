package edu.uc.chi.emerse.sso;

import java.io.IOException;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.AlgorithmParameters;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.Signature;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECFieldFp;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPublicKeySpec;
import java.time.Clock;
import java.util.Base64;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.apache.tomcat.util.json.JSONParser;
import org.apache.tomcat.util.json.ParseException;

/**
 * Verifies the ES256 JWT that CHI Authentication sends as SSO-Assertion (lib/sso.js in
 * the auth project) and returns its subject, the CHI username.
 *
 * Only ES256 on P-256 is accepted, whatever the token header claims, so there is no
 * "alg: none" or algorithm-confusion path. Keys come from a copy of
 * https://chi-tools.uc.edu/auth/.well-known/jwks.json pinned on disk, because UC Health
 * hosts can't reliably reach UC at runtime and a pinned key can't be swapped by DNS.
 */
public final class AssertionVerifier
{
	private static final Base64.Decoder B64URL = Base64.getUrlDecoder();

	private final Map<String, ECPublicKey> keys;
	private final String issuer;
	private final String audience;
	private final long clockSkewSeconds;
	private final Clock clock;

	public AssertionVerifier(Map<String, ECPublicKey> keys, String issuer, String audience, long clockSkewSeconds, Clock clock)
	{
		if (keys.isEmpty()) throw new IllegalArgumentException("no ES256 keys in the JWKS");
		this.keys = Map.copyOf(keys);
		this.issuer = require(issuer, "issuer");
		this.audience = require(audience, "audience");
		this.clockSkewSeconds = clockSkewSeconds;
		this.clock = clock;
	}

	/** The verified subject, or an exception saying why the token is unacceptable. */
	public String verify(String token) throws InvalidAssertionException
	{
		var parts = token.split("\\.", -1);
		if (parts.length != 3) throw new InvalidAssertionException("not a compact JWS");

		var header = jsonObject(parts[0], "header");
		if (!"ES256".equals(header.get("alg"))) throw new InvalidAssertionException("alg is not ES256");
		var key = keyFor(header.get("kid"));

		try
		{
			var sig = Signature.getInstance("SHA256withECDSAinP1363Format");
			sig.initVerify(key);
			sig.update((parts[0] + "." + parts[1]).getBytes(StandardCharsets.US_ASCII));
			if (!sig.verify(decode(parts[2], "signature"))) throw new InvalidAssertionException("bad signature");
		}
		catch (GeneralSecurityException e)
		{
			throw new InvalidAssertionException("bad signature", e);
		}

		var claims = jsonObject(parts[1], "payload");
		if (!issuer.equals(claims.get("iss"))) throw new InvalidAssertionException("wrong issuer");
		if (!audienceMatches(claims.get("aud"))) throw new InvalidAssertionException("wrong audience");

		var now = clock.instant().getEpochSecond();
		var exp = seconds(claims.get("exp"), "exp");
		if (exp == null) throw new InvalidAssertionException("no exp");
		if (now > exp + clockSkewSeconds) throw new InvalidAssertionException("expired");
		var nbf = seconds(claims.get("nbf"), "nbf");
		if (nbf != null && now + clockSkewSeconds < nbf) throw new InvalidAssertionException("not yet valid");
		var iat = seconds(claims.get("iat"), "iat");
		if (iat != null && now + clockSkewSeconds < iat) throw new InvalidAssertionException("issued in the future");

		if (!(claims.get("sub") instanceof String sub) || sub.isBlank())
			throw new InvalidAssertionException("no subject");
		return sub;
	}

	private ECPublicKey keyFor(Object kid) throws InvalidAssertionException
	{
		if (kid instanceof String k)
		{
			var key = keys.get(k);
			if (key == null) throw new InvalidAssertionException("unknown kid");
			return key;
		}
		if (kid == null && keys.size() == 1) return keys.values().iterator().next();
		throw new InvalidAssertionException("no usable kid");
	}

	private boolean audienceMatches(Object aud)
	{
		if (aud instanceof String s) return audience.equals(s);
		if (aud instanceof Collection<?> c) return c.contains(audience);
		return false;
	}

	public static AssertionVerifier fromJwksFile(Path jwks, String issuer, String audience, long clockSkewSeconds)
		throws IOException, GeneralSecurityException
	{
		return new AssertionVerifier(parseJwks(Files.readString(jwks)), issuer, audience, clockSkewSeconds, Clock.systemUTC());
	}

	/** kid → key for every P-256 signing key in a JWKS document; other keys are skipped. */
	public static Map<String, ECPublicKey> parseJwks(String json) throws GeneralSecurityException
	{
		Map<String, Object> doc;
		try
		{
			doc = new JSONParser(json).parseObject();
		}
		catch (ParseException e)
		{
			throw new GeneralSecurityException("JWKS is not valid JSON", e);
		}
		if (!(doc.get("keys") instanceof List<?> list)) throw new GeneralSecurityException("JWKS has no keys array");

		var params = AlgorithmParameters.getInstance("EC");
		params.init(new ECGenParameterSpec("secp256r1"));
		var p256 = params.getParameterSpec(ECParameterSpec.class);
		var factory = KeyFactory.getInstance("EC");

		var keys = new LinkedHashMap<String, ECPublicKey>();
		for (var o : list)
		{
			if (!(o instanceof Map<?, ?> jwk)) continue;
			if (!"EC".equals(jwk.get("kty")) || !"P-256".equals(jwk.get("crv"))) continue;
			if (jwk.get("use") != null && !"sig".equals(jwk.get("use"))) continue;
			if (jwk.get("alg") != null && !"ES256".equals(jwk.get("alg"))) continue;
			if (!(jwk.get("kid") instanceof String kid)) continue;
			var x = new BigInteger(1, B64URL.decode((String) jwk.get("x")));
			var y = new BigInteger(1, B64URL.decode((String) jwk.get("y")));
			requireOnCurve(x, y, p256);
			keys.put(kid, (ECPublicKey) factory.generatePublic(new ECPublicKeySpec(new ECPoint(x, y), p256)));
		}
		return keys;
	}

	/** The JDK's KeyFactory doesn't check this, so a corrupted JWKS would load silently. */
	private static void requireOnCurve(BigInteger x, BigInteger y, ECParameterSpec spec) throws GeneralSecurityException
	{
		var curve = spec.getCurve();
		var p = ((ECFieldFp) curve.getField()).getP();
		if (x.signum() < 0 || x.compareTo(p) >= 0 || y.signum() < 0 || y.compareTo(p) >= 0)
			throw new GeneralSecurityException("JWKS key coordinates out of range");
		var lhs = y.multiply(y).mod(p);
		var rhs = x.pow(3).add(curve.getA().multiply(x)).add(curve.getB()).mod(p);
		if (!lhs.equals(rhs)) throw new GeneralSecurityException("JWKS key is not on P-256");
	}

	private static Map<String, Object> jsonObject(String part, String what) throws InvalidAssertionException
	{
		try
		{
			return new JSONParser(new String(decode(part, what), StandardCharsets.UTF_8)).parseObject();
		}
		catch (ParseException | RuntimeException e)
		{
			throw new InvalidAssertionException(what + " is not a JSON object", e);
		}
	}

	private static byte[] decode(String part, String what) throws InvalidAssertionException
	{
		try
		{
			return B64URL.decode(part);
		}
		catch (IllegalArgumentException e)
		{
			throw new InvalidAssertionException(what + " is not base64url", e);
		}
	}

	private static Long seconds(Object value, String claim) throws InvalidAssertionException
	{
		if (value == null) return null;
		if (value instanceof Number n) return n.longValue();
		throw new InvalidAssertionException(claim + " is not a number");
	}

	private static String require(String value, String name)
	{
		if (value == null || value.isBlank()) throw new IllegalArgumentException(name + " is required");
		return value;
	}
}
