Purpose of this fork
====================

* Added support for instance variables
* Added support for symbolic links (;)
* Added support for links (@)

With these patches, you can unmarshal safely Rails' session cookies,
even if they contain stuff in the Flash (the original upstream crashed
when parsing a session with something in the Flash).

Tested with Ruby 1.9 marshalled data, with encodings attached to strings.

Have fun :-)

-vjt

Main
====

Most comprehensive guide to Ruby marshal you can find here:

http://spec.ruby-doc.org/wiki/Marshaling

or read C source in Ruby sources tree:

http://www.ruby-doc.org/doxygen/1.8.4/marshal_8c-source.html

Examples
========

Ruby:

    cookie = {
      :user_id => 1024,
      :session_id => '56588901e819883d90fec315f4331bc2'
    }

    File.open('cookie.bin', 'w') do |f|
      f.write(Marshal.dump(cookie))
    end

Erlang:

    1> marshal:parse_file("cookie.bin").
    [[{session_id,"56588901e819883d90fec315f4331bc2"},
      {user_id,1024}]]


    % Extract User ID from Rails' session cookie
    %
    % generate_digest is in rcookie.erl
    % unquote is in misultin (http://github.com/ostinelli/misultin)
    % Sorry for the mess ;-)
    %
    extract_uid(CookieString) ->
      Cookies = mochiweb_cookies:parse_cookie(CookieString),
      case proplists:get_value(?SESSION_NAME, Cookies) of
        undefined -> false;

        SignedSession ->
          [Session, Signature] = string:tokens(unquote(SignedSession), "--"),

          case generate_digest(Session) == Signature of
            true ->
              [Data] = marshal:decode(base64:decode(Session)),
              Uid = proplists:get_value(user_id, Data),
              case Uid of
                undefined -> false;
                _         -> Uid
              end;

            _ -> false
          end
      end.
