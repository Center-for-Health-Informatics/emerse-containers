package edu.uc.chi.emerse.sso;

import java.io.IOException;
import java.nio.file.Path;
import java.util.List;
import java.util.regex.Pattern;

import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletResponse;

import org.apache.catalina.LifecycleException;
import org.apache.catalina.Session;
import org.apache.catalina.connector.Request;
import org.apache.catalina.connector.Response;
import org.apache.catalina.realm.GenericPrincipal;
import org.apache.catalina.valves.ValveBase;
import org.apache.juli.logging.Log;
import org.apache.juli.logging.LogFactory;

/**
 * Sets the request's user principal from a verified CHI Authentication SSO-Assertion, so
 * that EMERSE's preauth profile (LoginService: {@code req.getRemoteUser()} when
 * {@code preauth.header} is unset) sees only a user that CHI Authentication signed for.
 *
 * A request with no assertion passes through with no user and EMERSE treats it as signed
 * out; if it carries a session this valve tagged, that session is expired first. A
 * request with an assertion that fails verification, or that arrives from
 * somewhere other than a trusted proxy, gets a 403: either nginx is misconfigured or
 * someone is forging the header, and neither should fall back to "anonymous".
 *
 * EMERSE keeps its user in the HTTP session and looks there first, so if the assertion
 * names someone other than the user the session was started for (sign out of CHI, sign
 * in as someone else, same browser), the session is expired before EMERSE sees it.
 *
 * <pre>
 * &lt;Valve className="edu.uc.chi.emerse.sso.SsoAssertionValve"
 *        jwksFile="/app/etc/chi-auth-jwks.json"
 *        issuer="https://chi-tools.uc.edu/auth/"
 *        audience="chi-tools.uc.edu"
 *        trustedProxies="172\.31\.246\.247"/&gt;
 * </pre>
 */
public class SsoAssertionValve extends ValveBase
{
	private static final Log LOG = LogFactory.getLog(SsoAssertionValve.class);

	/** Session note holding the CHI username the session was started for. */
	static final String SESSION_USER_NOTE = "edu.uc.chi.emerse.sso.user";

	static final String AUTH_TYPE = "CHI-SSO";

	private String jwksFile;
	private String issuer;
	private String audience;
	private String headerName = "SSO-Assertion";
	private Pattern trustedProxies;
	private long clockSkewSeconds = 30;
	private boolean stripAuthorization = true;

	private AssertionVerifier verifier;

	public SsoAssertionValve()
	{
		super(true);
	}

	@Override
	protected void initInternal() throws LifecycleException
	{
		super.initInternal();
		if (jwksFile == null) throw new LifecycleException("SsoAssertionValve: jwksFile is required");
		try
		{
			verifier = AssertionVerifier.fromJwksFile(Path.of(jwksFile), issuer, audience, clockSkewSeconds);
		}
		catch (Exception e)
		{
			throw new LifecycleException("SsoAssertionValve: can't load " + jwksFile + ": " + e.getMessage(), e);
		}
		if (trustedProxies == null)
			LOG.warn("SsoAssertionValve: trustedProxies is not set; assertions are accepted from any address");
	}

	@Override
	public void invoke(Request request, Response response) throws IOException, ServletException
	{
		// EMERSE still honours HTTP Basic against LOGIN_ACCOUNT passwords (LoginService
		// loginBasic); behind CHI Authentication the only credential is the assertion
		if (stripAuthorization) request.getCoyoteRequest().getMimeHeaders().removeHeader("authorization");

		var token = request.getHeader(headerName);
		if (token == null || token.isEmpty())
		{
			// a session started under an assertion is only good alongside one, so a stolen
			// cookie can't be replayed straight at Tomcat
			expireIfSomeoneElse(request.getSessionInternal(false), null);
			getNext().invoke(request, response);
			return;
		}

		var remote = request.getRemoteAddr();
		if (trustedProxies != null && !trustedProxies.matcher(remote).matches())
		{
			LOG.warn("SsoAssertionValve: " + headerName + " from untrusted address " + remote);
			response.sendError(HttpServletResponse.SC_FORBIDDEN);
			return;
		}

		String username;
		try
		{
			username = verifier.verify(token);
		}
		catch (InvalidAssertionException e)
		{
			LOG.warn("SsoAssertionValve: rejected " + headerName + " from " + remote + ": " + e.getMessage());
			response.sendError(HttpServletResponse.SC_FORBIDDEN);
			return;
		}

		expireIfSomeoneElse(request.getSessionInternal(false), username);
		request.setAuthType(AUTH_TYPE);
		request.setUserPrincipal(new GenericPrincipal(username, List.of()));

		getNext().invoke(request, response);

		// tag a session EMERSE created (or one from before this valve) with its user
		var session = request.getSessionInternal(false);
		if (session != null && session.isValid() && session.getNote(SESSION_USER_NOTE) == null)
			session.setNote(SESSION_USER_NOTE, username);
	}

	/** Expire a session tagged for anyone but username (null: a request with no assertion). */
	static void expireIfSomeoneElse(Session session, String username)
	{
		if (session == null || !session.isValid()) return;
		var owner = session.getNote(SESSION_USER_NOTE);
		if (owner != null && !owner.equals(username))
		{
			LOG.info("SsoAssertionValve: session belonged to " + owner + ", request is from " +
				(username == null ? "no one (no assertion)" : username) + "; expiring it");
			session.expire();
		}
	}

	public void setJwksFile(String jwksFile)
	{
		this.jwksFile = jwksFile;
	}

	public void setIssuer(String issuer)
	{
		this.issuer = issuer;
	}

	public void setAudience(String audience)
	{
		this.audience = audience;
	}

	public void setHeaderName(String headerName)
	{
		this.headerName = headerName;
	}

	/** A regular expression the remote address must match, like RemoteIpValve's internalProxies. */
	public void setTrustedProxies(String trustedProxies)
	{
		this.trustedProxies = trustedProxies == null || trustedProxies.isBlank() ? null : Pattern.compile(trustedProxies);
	}

	public void setClockSkewSeconds(long clockSkewSeconds)
	{
		this.clockSkewSeconds = clockSkewSeconds;
	}

	public void setStripAuthorization(boolean stripAuthorization)
	{
		this.stripAuthorization = stripAuthorization;
	}
}
