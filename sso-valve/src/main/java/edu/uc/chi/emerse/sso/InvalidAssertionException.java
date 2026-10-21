package edu.uc.chi.emerse.sso;

public class InvalidAssertionException extends Exception
{
	public InvalidAssertionException(String message)
	{
		super(message);
	}

	public InvalidAssertionException(String message, Throwable cause)
	{
		super(message, cause);
	}
}
