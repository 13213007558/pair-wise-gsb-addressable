# Addressable

<dl>
  <dt>Homepage</dt><dd><a href="https://github.com/sporkmonger/addressable">github.com/sporkmonger/addressable</a></dd>
  <dt>Author</dt><dd><a href="mailto:bob@sporkmonger.com">Bob Aman</a></dd>
  <dt>Copyright</dt><dd>Copyright © Bob Aman</dd>
  <dt>License</dt><dd>Apache 2.0</dd>
</dl>

[![Gem Version](https://img.shields.io/gem/dt/addressable.svg)][gem]
[![Build Status](https://github.com/sporkmonger/addressable/workflows/CI/badge.svg)][actions]
[![Test Coverage Status](https://img.shields.io/coveralls/sporkmonger/addressable.svg)][coveralls]
[![Documentation Coverage Status](https://inch-ci.org/github/sporkmonger/addressable.svg?branch=master)][inch]

[gem]: https://rubygems.org/gems/addressable
[actions]: https://github.com/sporkmonger/addressable/actions
[coveralls]: https://coveralls.io/r/sporkmonger/addressable
[inch]: https://inch-ci.org/github/sporkmonger/addressable

## Description

Addressable is an alternative implementation to the URI implementation
that is part of Ruby's standard library. It is flexible, offers heuristic
parsing, and additionally provides extensive support for IRIs and URI templates.

Addressable closely conforms to RFC 3986, RFC 3987, RFC 6570 (level 4),
and RFC 8141 (URNs).

## Reference

- {Addressable::URI}
- {Addressable::URN}
- {Addressable::Template}

## Example usage

```ruby
require "addressable/uri"

uri = Addressable::URI.parse("http://example.com/path/to/resource/")
uri.scheme
#=> "http"
uri.host
#=> "example.com"
uri.path
#=> "/path/to/resource/"

uri = Addressable::URI.parse("http://www.詹姆斯.com/")
uri.normalize
#=> #<Addressable::URI:0xc9a4c8 URI:http://www.xn--8ws00zhy3a.com/>
```


## URNs (RFC 8141)

`Addressable::URN` is a subclass of `Addressable::URI`, so the generic
accessors (`path`, `query`, `fragment`) keep working, while dedicated
accessors expose the URN structure: `nid`, `nss`, `r_component`,
`q_component` and `f_component`.

```ruby
require "addressable/urn"

urn = Addressable::URN.parse("urn:isbn:0451450523?+resolver?=q#section-2")
urn.nid          #=> "isbn"
urn.nss          #=> "0451450523"
urn.r_component  #=> "resolver"   (introduced by "?+")
urn.q_component  #=> "q"          (introduced by "?=")
urn.f_component  #=> "section-2"
urn.path         #=> "isbn:0451450523" (generic URI view)
urn.query        #=> "?+resolver?=q"  (generic URI view)
```

The r/q/f-components are not part of the resource identity; use
`lexically_equivalent?` (aliased as `same_resource?`) to compare URNs
without them.  Normalization lowercases the scheme and NID and upcases
percent-encoding hex digits, but never lowercases the NSS.  Per-namespace
normalization rules can be registered, and unknown namespaces receive only
the minimal processing allowed by RFC 8141:

```ruby
Addressable::URN.register_namespace("isbn") { |u| u.nss.delete("-") }
Addressable::URN.parse("urn:ISBN:0-451-45052-3").normalize.to_s
#=> "urn:isbn:0451450523"

a = Addressable::URN.parse("urn:example:a%2Fb")
b = Addressable::URN.parse("urn:EXAMPLE:a%2fb?=q#f")
a.same_resource?(b)  #=> true
a == b               #=> false (different r/q/f-components)
```


## URI Templates

For more details, see [RFC 6570](https://www.rfc-editor.org/rfc/rfc6570.txt).


```ruby

require "addressable/template"

template = Addressable::Template.new("http://example.com/{?query*}")
template.expand({
  "query" => {
    'foo' => 'bar',
    'color' => 'red'
  }
})
#=> #<Addressable::URI:0xc9d95c URI:http://example.com/?foo=bar&color=red>

template = Addressable::Template.new("http://example.com/{?one,two,three}")
template.partial_expand({"one" => "1", "three" => 3}).pattern
#=> "http://example.com/?one=1{&two}&three=3"

template = Addressable::Template.new(
  "http://{host}{/segments*}/{?one,two,bogus}{#fragment}"
)
uri = Addressable::URI.parse(
  "http://example.com/a/b/c/?one=1&two=2#foo"
)
template.extract(uri)
#=>
# {
#   "host" => "example.com",
#   "segments" => ["a", "b", "c"],
#   "one" => "1",
#   "two" => "2",
#   "fragment" => "foo"
# }
```

## Install

```console
$ gem install addressable
```

You may optionally turn on native IDN support by installing libidn and the
idn gem:

```console
$ sudo apt-get install libidn11-dev # Debian/Ubuntu
$ brew install libidn # OS X
$ gem install idn-ruby
```

## Semantic Versioning

This project uses [Semantic Versioning](https://semver.org/). You can (and should) specify your
dependency using a pessimistic version constraint covering the major and minor
values:

```ruby
spec.add_dependency 'addressable', '~> 2.7'
```

If you need a specific bug fix, you can also specify minimum tiny versions
without preventing updates to the latest minor release:

```ruby
spec.add_dependency 'addressable', '~> 2.3', '>= 2.3.7'
```
