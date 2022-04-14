#!/usr/bin/env raku
unit module Ed25519;

sub sha512(blob8 $b) returns blob8 {
  given run <openssl dgst -sha512 -binary>, :in, :out, :bin {
    .in.write: $b;
    .in.close;
    return .out.slurp: :close;
  }
}

sub blob-to-int(blob8 $b) returns UInt {
  $b.list.reverse.reduce(256 * * + *)
}

constant b = 256;
constant p = 2**255 - 19;
constant L = 2**252 + 27742317777372353535851937790883648493;
constant a = -1 + p;

sub postfix:<⁻¹>(UInt $n where $n > 0) returns UInt { expmod($n, p - 2, p) }
multi infix:</>(Int $a, UInt $b) returns UInt { $a*$b⁻¹ mod p }

constant d = -121665/121666;

package FiniteFieldArithmetics {
  multi prefix:<->(UInt $n          --> UInt) is export { callsame() mod p }
  multi infix:<+> (UInt $a, UInt $b --> UInt) is export { callsame() mod p }
  multi infix:<-> (UInt $a, UInt $b --> UInt) is export { callsame() mod p }
  multi infix:<*> (UInt $a, UInt $b --> UInt) is export { callsame() mod p }
  multi infix:<**>(UInt $a, UInt $b --> UInt) is export { expmod($a, $b, p) }
}

sub bit($h,$i) { ($h[$i div 8] +> ($i%8)) +& 1 }

class Point {
  has UInt ($.x, $.y, $.z, $.t);
  multi method new(UInt:D $x, $y) {
    import FiniteFieldArithmetics;
    die "point ($x, $y) is not on the curve" unless
      a*$x*$x + $y*$y == 1 + d*$x*$x*$y*$y;
    self.bless: :$x, :$y, :z(1), :t($x*$y);
  }
  multi method new(Int:U $, $y) {
    import FiniteFieldArithmetics;
    my ($u, $v) = ($y*$y - 1, d*$y*$y + 1);
    my $x = $u*$v**3*($u*$v**7)**(-5/8);
    if $v*$x*$x == -$u  { $x = $x * 2**(-1/4) }
    if ($x % 2 != 0) { $x = -$x }
    return samewith($x, $y);
  }
  multi method new(blob8 $b where $b == b div 8) {
    my $y = [+] (^(b-1)).map({2**$_*bit($b,$_)});
    my $x = ::?CLASS.new(Int, $y).x;
    if $x +& 1 != bit($b, b-1) { $x = p - $x }
    samewith($x, $y);
  }

  method blob {
    blob8.new:
      ($!y/$!z)
      .polymod(2 xx (b-2))
      .Array.append(($!x/$!z) +& 1)
      .reverse
      .rotor(8)
      .map(*.reduce: 2 * * + *)
      .reverse
  }
  method ACCEPTS(::?CLASS $other) { self.blob.ACCEPTS($other.blob) }

  method add(::?CLASS $other --> ::?CLASS) {
    import FiniteFieldArithmetics;
    my (\X1, \Y1, \Z1, \T1) = ($!x, $!y, $!z, $!t);
    my (\X2, \Y2, \Z2, \T2) = ($other.x, $other.y, $other.z, $other.t);
    my \A = (Y1 - X1)*(Y2 - X2);
    my \B = (Y1 + X1)*(Y2 + X2);
    my \C = T1*2*d*T2;
    my \D = Z1*2*Z2;
    my \E = B - A;
    my \F = D - C;
    my \G = D + C;
    my \H = B + A;
    my \X3 = E*F;
    my \Y3 = G*H;
    my \T3 = E*H;
    my \Z3 = F*G;
    ::?CLASS.new: :x(X3), :y(Y3), :z(Z3), :t(T3);
  }
  method double(--> ::?CLASS) {
    import FiniteFieldArithmetics;
    my (\X1, \Y1, \Z1, \T1) = ($!x, $!y, $!z, $!t);
    my \A = X1**2;
    my \B = Y1**2;
    my \C = 2*Z1**2;
    my \H = A + B;
    my \E = H - (X1 + Y1)**2;
    my \G = A - B;
    my \F = C + G;
    my \X3 = E*F;
    my \Y3 = G*H;
    my \T3 = E*H;
    my \Z3 = F*G;
    ::?CLASS.new: :x(X3), :y(Y3), :z(Z3), :t(T3);
  }

}
multi sub infix:<*>(0, Point $ ) returns Point { return Point.new: 0, 1 }
multi sub infix:<*>(1, Point $p) returns Point { return $p }
multi sub infix:<*>(2, Point $p) returns Point { return $p.double }
multi sub infix:<*>($n, Point $p) returns Point {
  return 2*(($n div 2)*$p) + ($n mod 2)*$p;
}

constant B = Point.new: Int, 4/5;

constant c = 3;
constant n = 254;

multi sub infix:<+>(Point $a, Point $b) returns Point { $a.add($b) }

our sub publickey($secret-key) {
  (((blob-to-int sha512 $secret-key) mod L) * B).blob
}

our sub sign($msg, $secret-key) {
  my $h = sha512($secret-key);
  my $s = $h.subbuf(0, 32);
  $s[0]   +&= 0b1111_1000;
  $s[*-1] +&= 0b0111_1111;
  $s[*-1] +|= 0b0100_0000;
  my $a = blob-to-int($s);
  my $A = ($a mod L) * B;
  my $r = blob-to-int(sha512($h.subbuf(32) ~ $msg));
  my $R = ($r mod L) * B;
  my $S = ($r + blob-to-int(sha512($R.blob ~ $A.blob ~ $msg)) * $a) mod L;
  $R.blob ~ blob8.new:
    $S.polymod(2 xx (b-1))
    .rotor(8)
    .map({:2[@$_]})
    .reverse;
}

our sub verify($message, $signature, $public-key) {
  if $signature.elems  != b div 4 { die "wrong signature length"  }
  if $public-key.elems != b div 8 { die "wrong public key length" }
  my Point $R .= new: $signature.subbuf(0, b div 8);
  my Point $A .= new: $public-key;
  my UInt  $S = blob-to-int($signature.subbuf(b div 8));
  my UInt  $h = blob-to-int(sha512($R.blob ~ $public-key ~ $message));
  die "wrong signature" unless $S * B ~~ $R + $h*$A;
}