# B2Evolution to Ghost migration script

In this repo you can find a script that generates a JSON file with all the
posts and tags you have in your B2Evolution MySQL database instance.

It connects directly to the database and generates the JSON structure on
standard output. The file can be piped to a file and directly imported into
a Ghost instance using the Settings / Labs / Import content feature.

## Installation

This is a simple Perl script, and requires some CPAN dependencies. The
dependencies are all listed in the cpanfile, and can usually be installed
either through your package manager (if you're using system perl), or using
the command `cpanm --installdeps .` if your using a custom perl instance.

If you use a custom perl and install directly from CPAN, make sure the
`mysql_config` program is installed (needed by DBD::mysql). It can usually
be installed with your system package manager. In Debian-based distros, it
is named `libmysqlclient-dev`.

## Usage

Fill in your database details in `.env`, using `.env.template` as a guide,
or set the environment variables in some other way. Make sure you know which
timezone has been used for all the timestamps in the b2evolution database,
as it doesn't use database timestamp fields with timezone information. Also
fill in this information in `.env`. If you don't set this, the script
defaults to `UTC`.

Fill in the MySQL database DSN and credentials for your Ghost instance into
`.env`, same as you did with the B2Evolution details.

This script expects your Ghost content database to be empty. If you run it
and your database is not empty, you might get unpredictable behavior,
duplicates or other issues. Go to Settings -> Labs and use the *Delete all
content* button if you've tried to import content and it failed.

Once you've imported the content using the exported JSON file, you can run
the script to migrate members and comments directly from the B2Evolution
database to the Ghost database. You'll need to delete all comments and
members before you perform the import, or you'll get errors.

## Limitations

The links directly associated with B2Evolution posts aren't migrated over.
Images used directly from B2Evolution are also not migrated and must be done
manually.

## License

This script is licensed with the same terms as Perl itself.

## Copyright

Robin Smidsrød (robin@smidsrod.no)
