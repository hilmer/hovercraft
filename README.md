We have the hovercraft. It is fast and it skims just above the surface.

There is much to be added to the hovercraft, but it already flies.

## Welcome to Hovercraft

An easy direct Erlang CouchDB library.

Use this to abstract CouchDB behind a simple Erlang function call. Currently supports the database and document APIs, with views on the way.

## Branch couchdb1.3.x
This branch works with couchb > 1.3.
The most significant compatibility change, is that it uses the mrargs record from couch_mrview.hrl

## Basic Usage

Hovercraft master is only compatible with CouchDB trunk. If the tests fail, 
make sure you are running on the latest latest CouchDB.

There is a 0.11 branch which is compatible with CouchDB 0.11. Use it when appropriate.

The easiest way to try Hovercraft is to put the hovercraft directory 
inside the CouchDB trunk directory and then launch CouchDB like this:

    erlc hovercraft/*erl && make dev && ERL_LIBS="hovercraft" utils/run -i

This will open an interactive session. To run the tests, call 
hovercraft:test/0 like this:

    1> hovercraft_test:all().
    [info] [<0.30.0>] Starting tests in <<"hovercraft-test">>
    ok

## Speed of Light

To run the speed of light test, run hovercraft:lightning/0 like this:

    2> hovercraft_test:lightning().
    Inserted 100000 docs in 14.967256 seconds with batch size of 1000. (6681.251393040915 docs/sec)
    ok

To try different tunings, you can call hovercraft:lightning/1 with 
custom batch sizes. The docs in the speed of light test are small, feel
free to edit the source code to try larger docs.

## Credits
Changed to use couchdb mrview, so it works with couchdb > 1.3
Copyright 2014 Søren Hilmer <sh@widetrail.dk>

Released at #CouchHack '09
Apache 2.0 License 
Copyright 2009 J. Chris Anderson <jchris@couch.io>
